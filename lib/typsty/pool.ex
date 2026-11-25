defmodule Typsty.Pool do
  @moduledoc """
  A pool of worker processes that render documents outside of the BEAM.

  By default, Typsty renders inside your VM. That's the fastest way to render, and it's
  protected against everything the data can do (see
  [What a template can do](Typsty.html#module-what-a-template-can-do)). A template is code,
  though, and a template that loops for a long time or allocates without bound can only be
  stopped by ending the process it runs in. The pool runs renders in separate OS processes,
  so that it can:

  - **stop a render at its timeout**, whatever it's doing, by ending its worker
  - **limit the memory** a render can use, ending its worker when it goes over
  - **contain crashes**: a worker that dies takes nothing else down

  A worker that's ended is replaced with a new one. Documents rendered in a pool can also
  read PDF files, which renders inside the VM refuse.

  ## Usage

  Add a pool to your supervision tree:

  ```elixir
  children = [
    {Typsty.Pool, name: MyApp.TypstPool, size: 4, memory_limit: 1_000_000_000}
  ]
  ```

  and render with it, per render or for every render:

  ```elixir
  MyApp.Invoice.to_pdf(assigns, pool: MyApp.TypstPool, timeout: 10_000)

  config :typsty, pool: MyApp.TypstPool
  ```

  Renders return what they return without a pool: the same output, warnings and errors,
  pointing at the same lines. Some errors are particular to the pool (see
  `Typsty.RenderError`): a render that runs past its timeout (`:timeout`), a render that
  waits past its timeout for a free worker (`:busy`), a render that goes over the memory
  limit (`:memory_limit`), and a worker that crashes or a pool that stops before or during
  the render (`:crashed`). A render can take up to a second longer than its timeout, while
  its worker is stopped.

  A pool serves the processes on its own node. A render's template, assigns and files may
  be at most 4 GiB together.

  ## Options

  #{Typsty.Options.docs(:pool)}

  ## Memory

  The memory limit counts what a worker allocates: the document being rendered, Typst's
  caches, and the fonts it has loaded, which it keeps (system fonts can be large: an emoji
  font can take 200 MB). Allow for those, and for the files a render is given, which the
  worker holds twice while it reads the request; a render whose template, assigns and files
  are larger than the limit fails without being sent. Each worker keeps its own fonts and
  caches, so a pool uses up to `size` times as much. The limit doesn't count thread stacks
  or the allocator's overhead, so the operating system sees somewhat more.

  A worker drops Typst's caches once they take half of the room left under the limit.

  Without a memory limit, a render that allocates without bound grows its worker until
  the operating system runs out of memory, and the system may then end another process
  than the worker (the BEAM, say). Set a limit when rendering templates or files you don't
  trust.

  ## How it works

  Each worker runs `typsty_worker`, a program built from the same code as the NIF, which
  Typsty installs next to it. The pool talks to it through a port. A worker renders one
  document at a time, and keeps Typst's caches and its fonts between renders, like the
  NIF does. When the pool starts, it checks that the program runs. A new worker joins the
  pool once it has loaded the fonts that renders use by default (as configured), so no
  render waits for that. A worker that fails to start is logged, and retried a second
  later.

  A worker exits as soon as its port closes, even in the middle of a render. That happens
  when a render times out, when the process that asked for the render exits, when the pool
  stops, and when the VM exits, so workers never outlive what they're working for. A render
  that runs past its timeout ends its worker itself, too. A worker also retires itself after
  Typst panicked in it, and when its table of file paths is nearly full, and is replaced.

  Rendering in a worker costs a little more than in the NIF: the template, the assigns,
  the files and the output are copied between processes, and a worker that replaces one
  that was ended starts with empty caches.
  """

  @behaviour NimblePool

  require Logger

  alias Typsty.Diagnostic

  # The exit statuses of typsty_worker (native/typsty_worker/src/main.rs)
  @exit_memory_limit 85
  @exit_timeout 86
  @exit_protocol 87

  # The version of the protocol between the pool and the worker, which `--check` prints
  @protocol_version 1

  # How long to wait for a worker to end itself after a render's timeout, before ending it
  @grace_period 1_000

  # The longest a receive can wait
  @max_wait 4_294_967_295

  # The most a request can be: a frame's length is 4 bytes
  @max_frame_size 4_294_967_295

  # How many workers a render tries when the ones it gets turn out to have exited
  @checkout_attempts 3

  # How a worker acknowledges a request: :started
  @started :erlang.term_to_binary(:started)

  # How long a worker that failed to start waits before the pool starts another
  @restart_delay 1_000

  # How long a new worker may take to scan its fonts
  @warm_up_timeout 60_000

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @typedoc "An option for `start_link/1`. See [Options](#module-options)."
  @type option :: unquote(Typsty.Options.typespec(:pool))

  @doc """
  Starts a pool. See [Options](#module-options) for the options.

  Raises `ArgumentError` for invalid options, and raises if the worker program can't run,
  before starting any workers.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    opts = Typsty.Options.pool!(opts)

    size = Keyword.get_lazy(opts, :size, &System.schedulers_online/0)
    memory_limit = opts[:memory_limit]
    max_renders = opts[:max_renders]

    executable = executable!()
    args = if(memory_limit, do: ["--memory-limit", Integer.to_string(memory_limit)], else: [])
    check_worker!(executable, args, memory_limit)

    pool_state = %{
      executable: executable,
      args: args,
      memory_limit: memory_limit,
      max_renders: max_renders
    }

    nimble_opts = [worker: {__MODULE__, pool_state}, pool_size: size]
    nimble_opts = if opts[:name], do: Keyword.put(nimble_opts, :name, opts[:name]), else: nimble_opts

    NimblePool.start_link(nimble_opts)
  end

  defp executable! do
    path = Path.join([:code.priv_dir(:typsty), "native", Typsty.WorkerBuild.executable_name()])

    if File.regular?(path) do
      path
    else
      raise ArgumentError,
            "Typsty.Pool can't find its worker program at #{path}. It's built with the NIF, or " <>
              "downloaded with it: try recompiling Typsty with `mix deps.compile typsty --force`"
    end
  end

  # Starts the worker program once, the way the workers start, so that a program that can't
  # run fails here rather than in every render
  defp check_worker!(executable, args, memory_limit) do
    result =
      try do
        System.cmd(executable, ["--check" | args])
      rescue
        error in ErlangError ->
          reraise RuntimeError,
                  [message: "Typsty.Pool can't run its worker program at #{executable}: #{Exception.message(error)}"],
                  __STACKTRACE__
      end

    case result do
      {output, 0} ->
        if output |> String.split("\n", trim: true) |> List.last() != "typsty_worker #{@protocol_version}" do
          raise "Typsty.Pool's worker program at #{executable} is from another version of Typsty " <>
                  "(it printed #{inspect(output)}). Recompile Typsty with `mix deps.compile typsty --force`"
        end

      {_output, @exit_memory_limit} ->
        raise ArgumentError, "the :memory_limit option (#{memory_limit} bytes) is too low for a worker to start"

      {output, status} ->
        raise "Typsty.Pool's worker program at #{executable} failed to start (#{describe_exit(status)}): " <>
                String.trim(output)
    end
  end

  @doc false
  # Renders in a worker. Takes the arguments of Typsty.Native.start_render/5 (the pool
  # aside), and returns what the NIF returns or sends, or {:error, reason, message}.
  @spec __render__(pid(), String.t(), map(), [{String.t(), binary()}], map()) ::
          {:ok, binary() | [binary()], [Diagnostic.t()]}
          | {:error, :typst, [Diagnostic.t()]}
          | {:error, atom(), String.t()}
  def __render__(pool, template, assigns, files, options) do
    deadline = options.timeout && System.monotonic_time(:millisecond) + options.timeout
    checkout(pool, {template, assigns, files, options}, deadline, @checkout_attempts)
  end

  # A worker that turns out to have exited while it was idle is replaced, and another one
  # is tried, within the deadline
  defp checkout(pool, request, deadline, attempts) do
    {_template, _assigns, _files, options} = request

    case remaining(deadline) do
      remaining when remaining == :infinity or remaining > 0 ->
        result =
          NimblePool.checkout!(
            pool,
            :render,
            fn {pool_pid, _ref}, worker -> render_in(worker, pool_pid, request, deadline) end,
            remaining
          )

        case result do
          :retry when attempts > 1 -> checkout(pool, request, deadline, attempts - 1)
          :retry -> {:error, :crashed, "the pool's workers had exited"}
          result -> result
        end

      _expired ->
        busy(options.timeout)
    end
  catch
    :exit, {:timeout, {NimblePool, :checkout, _}} ->
      {_template, _assigns, _files, options} = request
      busy(options.timeout)

    :exit, {_reason, {NimblePool, :checkout, _}} ->
      {:error, :crashed, "the pool stopped before the render started"}
  end

  defp render_in(%{port: port} = worker, pool_pid, request, deadline) do
    case take(port) do
      {:ok, monitor} ->
        pool_monitor = Process.monitor(pool_pid)

        try do
          send_request(port, request, remaining(deadline), {monitor, pool_pid, pool_monitor}, worker)
        after
          Process.demonitor(monitor, [:flush])
          Process.demonitor(pool_monitor, [:flush])
        end
        |> give_back(worker, pool_pid)

      # The worker exited while it was in the pool
      :error ->
        {:retry, :remove}
    end
  end

  defp send_request(port, {template, assigns, files, options}, remaining, monitors, worker)
       when remaining == :infinity or remaining > 0 do
    timeout = if remaining == :infinity, do: nil, else: remaining
    request = :erlang.term_to_iovec({:render, template, assigns, files, %{options | timeout: timeout}})
    size = :erlang.iolist_size(request)

    cond do
      # A frame's length is 4 bytes
      size > @max_frame_size ->
        {:unused,
         {:error, :invalid,
          "the template, assigns and files are #{size} bytes together, more than a Typsty.Pool " <>
            "worker can be sent (#{@max_frame_size} bytes)"}}

      worker.memory_limit && size > worker.memory_limit ->
        {:unused,
         {:error, :memory_limit,
          "the template, assigns and files are #{size} bytes together, more than the pool's " <>
            "memory limit (#{worker.memory_limit} bytes)"}}

      true ->
        try do
          Port.command(port, request)
        rescue
          # The port closed since it was taken: the worker had exited
          ArgumentError -> :retry
        else
          true -> await_start(port, monitors, worker, remaining, options.timeout)
        end
    end
  end

  # The deadline passed while waiting for a worker
  defp send_request(_port, {_template, _assigns, _files, options}, _expired, _monitors, _worker) do
    {:unused, busy(options.timeout)}
  end

  # The worker acknowledges a request as soon as it reads it. A worker that exits before
  # that had died before it got the request (killed while it was idle, say), so the render
  # goes to another worker
  defp await_start(port, {monitor, pool_pid, pool_monitor} = monitors, worker, remaining, timeout) do
    wait = if remaining == :infinity, do: :infinity, else: min(remaining + @grace_period, @max_wait)

    receive do
      {^port, {:data, @started}} ->
        await(port, monitors, worker, remaining, timeout)

      {^port, {:exit_status, _status}} ->
        :retry

      {:DOWN, ^pool_monitor, :process, _pid, _reason} ->
        close(port)
        {:exited, {:error, :crashed, "the pool stopped before the render started"}}

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        if Process.alive?(pool_pid),
          do: :retry,
          else: {:exited, {:error, :crashed, "the pool stopped before the render started"}}
    after
      wait ->
        close(port)
        {:exited, timed_out(timeout)}
    end
  end

  # The worker's port is taken over for the render, so that its messages come here. It's
  # monitored rather than linked: a pool that stops while the port is here ends the port,
  # which must not end this process too. Port.connect/2 links them for a moment, so exits
  # are trapped meanwhile.
  defp take(port) do
    trapping = Process.flag(:trap_exit, true)

    try do
      Port.connect(port, self())
      Process.unlink(port)

      receive do
        {:EXIT, ^port, _reason} -> :ok
      after
        0 -> :ok
      end

      {:ok, Port.monitor(port)}
    rescue
      ArgumentError -> :error
    after
      Process.flag(:trap_exit, trapping)
    end
  end

  defp await(port, {monitor, pool_pid, pool_monitor}, worker, remaining, timeout) do
    wait = if remaining == :infinity, do: :infinity, else: min(remaining + @grace_period, @max_wait)

    receive do
      {^port, {:data, data}} ->
        reply(port, data)

      {^port, {:exit_status, status}} ->
        {:exited, exit_error(status, worker, timeout)}

      {:DOWN, ^pool_monitor, :process, _pid, _reason} ->
        close(port)
        {:exited, {:error, :crashed, "the pool stopped during the render"}}

      # The pool ends its ports when it stops, which can be noticed before the pool's end
      {:DOWN, ^monitor, :port, ^port, _reason} ->
        if Process.alive?(pool_pid) do
          {:exited, {:error, :crashed, "the render's worker exited during the render"}}
        else
          {:exited, {:error, :crashed, "the pool stopped during the render"}}
        end
    after
      wait ->
        # Closing the port ends the worker
        close(port)
        {:exited, timed_out(timeout)}
    end
  end

  # The worker's response, which must be one of the results the NIF gives
  defp reply(port, data) do
    case :erlang.binary_to_term(data, [:safe]) do
      {:ok, _output, _warnings} = reply -> {:reply, reply}
      {:error, reason, _details} = reply when is_atom(reason) -> {:reply, reply}
      _other -> raise ArgumentError
    end
  rescue
    ArgumentError ->
      close(port)
      {:exited, {:error, :crashed, "the render's worker sent a response that couldn't be read"}}
  end

  defp give_back(:retry, %{port: port}, _pool_pid) do
    close(port)
    {:retry, :remove}
  end

  defp give_back({:reply, reply}, %{port: port}, pool_pid), do: {reply, give_back_port(port, pool_pid, :ok)}
  defp give_back({:unused, reply}, %{port: port}, pool_pid), do: {reply, give_back_port(port, pool_pid, :unused)}

  defp give_back({:exited, error}, %{port: port}, _pool_pid) do
    close(port)
    {error, :remove}
  end

  # The port goes back to the pool with the worker
  defp give_back_port(port, pool_pid, checkin) do
    Port.connect(port, pool_pid)
    checkin
  rescue
    # The port or the pool is gone
    ArgumentError ->
      close(port)
      :remove
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp remaining(nil), do: :infinity
  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp exit_error(@exit_timeout, _worker, timeout), do: timed_out(timeout)

  defp exit_error(@exit_memory_limit, worker, _timeout) do
    {:error, :memory_limit,
     "the render used more than the pool's memory limit (#{worker.memory_limit} bytes), and was stopped"}
  end

  defp exit_error(status, _worker, _timeout) do
    {:error, :crashed, "the render's worker crashed (#{describe_exit(status)})"}
  end

  defp describe_exit(@exit_protocol), do: "it lost track of its requests"

  defp describe_exit(status) when status > 128 do
    case {:os.type(), status - 128} do
      {{:unix, _}, 9} -> "it was killed by signal 9, perhaps by the system, for running out of memory"
      {{:unix, _}, signal} -> "it was killed by signal #{signal}"
      _windows -> "it exited with status #{status}"
    end
  end

  defp describe_exit(status), do: "it exited with status #{status}"

  defp timed_out(timeout) do
    {:error, :timeout, "rendering didn't finish within the timeout (#{timeout} ms), and its worker was stopped"}
  end

  defp busy(timeout) do
    {:error, :busy, "rendering didn't start within the timeout (#{timeout} ms): every worker in the pool was busy"}
  end

  # NimblePool callbacks

  @impl NimblePool
  def init_pool(pool_state) do
    # Responses are decoded with binary_to_term(data, [:safe]), which only accepts atoms
    # that exist, such as Typsty.Diagnostic's fields
    Code.ensure_loaded!(Diagnostic)
    {:ok, pool_state}
  end

  @impl NimblePool
  # A worker starts in the background, and joins the pool once it has scanned the fonts
  # renders use by default, so that no render waits for that (or times out waiting)
  def init_worker(pool_state) do
    pool_pid = self()
    {:async, fn -> start_worker(pool_state, pool_pid) end, pool_state}
  end

  defp start_worker(%{executable: executable, args: args, memory_limit: memory_limit}, pool_pid) do
    port =
      try do
        Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, :hide, packet: 4, args: args])
      rescue
        error in ErlangError -> failed_to_start(Exception.message(error))
      end

    warm_up(port)

    # The port goes to the pool, so that it outlives this process
    Port.connect(port, pool_pid)
    Process.unlink(port)
    %{port: port, memory_limit: memory_limit, renders: 0}
  end

  # Renders an empty document with the default options, which loads their fonts
  defp warm_up(port) do
    options =
      try do
        Typsty.Options.render!([])
      rescue
        # The config is invalid, which renders report
        ArgumentError -> nil
      end

    if options do
      options = options |> Typsty.__native_options__(:svg) |> Map.put(:timeout, nil)
      Port.command(port, :erlang.term_to_iovec({:render, "", %{}, [], options}))

      receive do
        {^port, {:data, @started}} -> warm_up_response(port)
        {^port, {:exit_status, status}} -> failed_to_start(describe_exit(status))
      after
        @warm_up_timeout ->
          close(port)
          failed_to_start("it didn't answer within #{div(@warm_up_timeout, 1000)} seconds")
      end
    end
  end

  defp warm_up_response(port) do
    receive do
      {^port, {:data, _response}} -> :ok
      {^port, {:exit_status, status}} -> failed_to_start(describe_exit(status))
    after
      @warm_up_timeout ->
        close(port)
        failed_to_start("it didn't answer within #{div(@warm_up_timeout, 1000)} seconds")
    end
  end

  # NimblePool starts another worker right away: waiting keeps a worker that can't start
  # from being restarted in a tight loop
  defp failed_to_start(why) do
    Logger.warning("a Typsty.Pool worker failed to start (#{why})")
    Process.sleep(@restart_delay)
    exit(:worker_failed_to_start)
  end

  @impl NimblePool
  # The process rendering with the worker takes its port over (see take/1). A worker whose
  # port has closed is replaced, and another one is checked out
  def handle_checkout(:render, _from, %{port: port} = worker, pool_state) do
    if Port.info(port) do
      {:ok, worker, worker, pool_state}
    else
      {:remove, :exited, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(:ok, _from, %{port: port} = worker, %{max_renders: max_renders} = pool_state) do
    worker = %{worker | renders: worker.renders + 1}

    cond do
      # The worker exited after its render. The pool didn't see that happen, since the
      # worker wasn't in the pool then
      Port.info(port) == nil -> {:remove, :exited, pool_state}
      max_renders && worker.renders >= max_renders -> {:remove, :max_renders, pool_state}
      true -> {:ok, worker, pool_state}
    end
  end

  # The worker wasn't used, as the request couldn't be sent
  def handle_checkin(:unused, _from, %{port: port} = worker, pool_state) do
    if Port.info(port), do: {:ok, worker, pool_state}, else: {:remove, :exited, pool_state}
  end

  def handle_checkin(:remove, _from, _worker, pool_state) do
    {:remove, :ended, pool_state}
  end

  @impl NimblePool
  # A worker that exits while it's idle is replaced. One that exits with status 0 retired
  # itself (after a panic, or with its table of file paths nearly full)
  def handle_info({port, {:exit_status, status}}, %{port: port}) do
    if status != 0 do
      Logger.warning("an idle Typsty.Pool worker exited (#{describe_exit(status)}), and is replaced")
    end

    {:remove, :exited}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port}), do: {:remove, :exited}

  # A worker must only answer requests: one that sends anything else is out of step
  def handle_info({port, {:data, _data}}, %{port: port}) do
    Logger.warning("an idle Typsty.Pool worker sent data it wasn't asked for, and is replaced")
    {:remove, :unexpected}
  end

  def handle_info(_message, worker), do: {:ok, worker}

  @impl NimblePool
  def terminate_worker(_reason, %{port: port}, pool_state) do
    close(port)
    {:ok, pool_state}
  end
end

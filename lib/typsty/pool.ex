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
  limit (`:memory_limit`), and a worker that crashes or a pool that stops during the render
  (`:crashed`). A render can take up to a second longer than its timeout, while its worker
  is stopped.

  A pool serves the processes on its own node.

  ## Options

  - `:name` - the name to register the pool under, to pass as the `:pool` option.
  - `:size` - the number of workers, which is how many renders can run at once. Defaults to
    the number of CPU cores (`System.schedulers_online/0`). A render waits for a free
    worker, within its timeout.
  - `:memory_limit` - the most memory, in bytes, each worker may use. A render that goes over
    it fails, and its worker is replaced. Defaults to `nil`, for no limit. See below.
  - `:max_renders` - replaces each worker after this many renders, which bounds the memory
    a long-running worker holds on to, and gives it a fresh table of file paths (see
    [Files](Typsty.html#module-files)). Defaults to `nil`, to keep workers for as long as
    they work.

  ## Memory

  The memory limit counts what a worker allocates: the document being rendered, Typst's
  caches, and the fonts it has loaded, which it keeps (system fonts can be large: an emoji
  font can take 200 MB). Allow for those, and for the files a render is given, which the
  worker holds while it renders. Each worker keeps its own fonts and caches, so a pool uses
  up to `size` times as much. The limit doesn't count thread stacks or the allocator's
  overhead, so the operating system sees somewhat more.

  A worker drops Typst's caches once they take half of the room left under the limit.

  ## How it works

  Each worker runs `typsty_worker`, a program built from the same code as the NIF, which
  Typsty installs next to it. The pool talks to it through a port. A worker renders one
  document at a time, and keeps Typst's caches and its fonts between renders, like the
  NIF does. When the pool starts, it checks that the program runs.

  A worker exits as soon as its port closes, even in the middle of a render. That happens
  when a render times out, when the process that asked for the render exits, when the pool
  stops, and when the VM exits, so workers never outlive what they're working for. A render
  that runs past its timeout ends its worker itself, too.

  Rendering in a worker costs a little more than in the NIF: the template, the variables,
  the files and the output are copied between processes, and a worker that replaces one
  that was ended starts with empty caches.
  """

  @behaviour NimblePool

  alias Typsty.Diagnostic

  # The exit statuses of typsty_worker (native/typsty_worker/src/main.rs)
  @exit_memory_limit 85
  @exit_timeout 86
  @exit_protocol 87

  # The version of the protocol between the pool and the worker, which `--check` prints
  @protocol_version 1

  # How long to wait for a worker to end itself after a render's timeout, before ending it
  @grace_period 1_000

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a pool. See the module documentation for the options.

  Raises if the worker program can't run, before starting any workers.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, size: System.schedulers_online(), memory_limit: nil, max_renders: nil])

    size = positive_integer!(opts[:size], :size)
    memory_limit = opts[:memory_limit] && positive_integer!(opts[:memory_limit], :memory_limit)
    max_renders = opts[:max_renders] && positive_integer!(opts[:max_renders], :max_renders)

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
        System.cmd(executable, ["--check" | args], stderr_to_stdout: true)
      rescue
        error in ErlangError ->
          reraise RuntimeError,
                  [message: "Typsty.Pool can't run its worker program at #{executable}: #{Exception.message(error)}"],
                  __STACKTRACE__
      end

    case result do
      {output, 0} ->
        if String.trim(output) != "typsty_worker #{@protocol_version}" do
          raise "Typsty.Pool's worker program at #{executable} is from another version of Typsty. " <>
                  "Recompile Typsty with `mix deps.compile typsty --force`"
        end

      {_output, @exit_memory_limit} ->
        raise ArgumentError, "the :memory_limit option (#{memory_limit} bytes) is too low for a worker to start"

      {output, status} ->
        raise "Typsty.Pool's worker program at #{executable} failed to start (#{describe_exit(status)}): " <>
                String.trim(output)
    end
  end

  defp positive_integer!(value, _option) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, option) do
    raise ArgumentError, "the #{inspect(option)} option must be a positive integer, got: #{inspect(value)}"
  end

  @doc false
  # Renders in a worker. Takes the arguments of Typsty.Native.start_render/5 (the pool
  # aside), and returns what the NIF sends, or {:error, reason, message}.
  @spec __render__(pid(), String.t(), map(), [{String.t(), binary()}], map()) ::
          {:ok, binary() | [binary()], [Diagnostic.t()]}
          | {:error, :typst, [Diagnostic.t()]}
          | {:error, atom(), String.t()}
  def __render__(pool, template, variables, files, options) do
    deadline = options.timeout && System.monotonic_time(:millisecond) + options.timeout

    NimblePool.checkout!(
      pool,
      :render,
      fn {pool_pid, _ref}, worker -> render_in(worker, pool_pid, {template, variables, files, options}, deadline) end,
      options.timeout || :infinity
    )
  catch
    :exit, {:timeout, {NimblePool, :checkout, _}} -> busy(options.timeout)
  end

  defp render_in(%{port: port} = worker, pool_pid, request, deadline) do
    case take(port) do
      {:ok, monitor} ->
        port
        |> send_request(request, remaining(deadline), monitor, worker)
        |> give_back(worker, pool_pid, monitor)

      :error ->
        {{:error, :crashed, "the render's worker had exited"}, :remove}
    end
  end

  defp send_request(port, {template, variables, files, options}, remaining, monitor, worker)
       when remaining == :infinity or remaining > 0 do
    timeout = if remaining == :infinity, do: nil, else: remaining
    request = {:render, template, variables, files, %{options | timeout: timeout}}
    Port.command(port, :erlang.term_to_iovec(request))

    await(port, monitor, worker, remaining, options.timeout)
  end

  # The deadline passed while waiting for a worker
  defp send_request(_port, {_template, _variables, _files, options}, _expired, _monitor, _worker) do
    {:reply, busy(options.timeout)}
  end

  # The worker's port is taken over for the render, so that its messages come here. It's
  # monitored rather than linked: a pool that stops while the port is here ends the port,
  # which must not end this process too.
  defp take(port) do
    Port.connect(port, self())
    Process.unlink(port)

    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end

    {:ok, Port.monitor(port)}
  rescue
    # The worker exited while it was in the pool
    ArgumentError -> :error
  end

  defp await(port, monitor, worker, remaining, timeout) do
    wait = if remaining == :infinity, do: :infinity, else: remaining + @grace_period

    receive do
      {^port, {:data, data}} ->
        {:reply, :erlang.binary_to_term(data, [:safe])}

      {^port, {:exit_status, status}} ->
        {:exited, exit_error(status, worker, timeout)}

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        {:exited, {:error, :crashed, "the pool stopped during the render"}}
    after
      wait ->
        # Closing the port ends the worker
        close(port)
        {:exited, timed_out(timeout)}
    end
  end

  defp give_back({:reply, reply}, %{port: port}, pool_pid, monitor) do
    Process.demonitor(monitor, [:flush])
    {reply, give_back_port(port, pool_pid)}
  end

  defp give_back({:exited, error}, %{port: port}, _pool_pid, monitor) do
    Process.demonitor(monitor, [:flush])
    close(port)
    {error, :remove}
  end

  # The port goes back to the pool with the worker
  defp give_back_port(port, pool_pid) do
    Port.connect(port, pool_pid)
    :ok
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

  defp describe_exit(@exit_protocol), do: "it couldn't read its request"
  defp describe_exit(137), do: "it was killed by signal 9, perhaps by the system, for running out of memory"
  defp describe_exit(status) when status > 128, do: "it was killed by signal #{status - 128}"
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
  def init_worker(%{executable: executable, args: args, memory_limit: memory_limit} = pool_state) do
    port =
      Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, :hide, packet: 4, args: args])

    {:ok, %{port: port, memory_limit: memory_limit, renders: 0}, pool_state}
  end

  @impl NimblePool
  # The process rendering with the worker takes its port over (see take/1)
  def handle_checkout(:render, _from, worker, pool_state) do
    {:ok, worker, worker, pool_state}
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

  def handle_checkin(:remove, _from, _worker, pool_state) do
    {:remove, :ended, pool_state}
  end

  @impl NimblePool
  # A worker that exits while it's idle is replaced
  def handle_info({port, {:exit_status, _status}}, %{port: port}), do: {:remove, :exited}
  def handle_info({:EXIT, port, _reason}, %{port: port}), do: {:remove, :exited}
  def handle_info(_message, worker), do: {:ok, worker}

  @impl NimblePool
  def terminate_worker(_reason, %{port: port}, pool_state) do
    close(port)
    {:ok, pool_state}
  end
end

defmodule Typsty.Pool do
  @moduledoc """
  A pool of worker processes that render documents outside of the BEAM.

  By default, Typsty renders inside your VM, with a NIF. That's the fastest way to render,
  and it's protected against everything data can do (see the README). A template is code,
  though, and a template that loops for a long time or allocates without bound can only be
  stopped by ending the process it runs in. The pool runs renders in separate OS processes,
  so that it can:

  - **stop a render at its timeout**, whatever it's doing, by ending its worker
  - **limit the memory** a render can use, ending its worker when it goes over
  - **contain crashes**: a worker that dies takes nothing else down

  A worker that's ended is replaced with a new one.

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
  pointing at the same lines. Three errors are particular to the pool: a render that runs
  past its timeout, a render that goes over the memory limit, and a worker that crashes.

  ## Options

  - `:name` - the name to register the pool under, to pass as the `:pool` option.
  - `:size` - the number of workers, which is how many renders can run at once. Defaults to
    the number of CPU cores (`System.schedulers_online/0`). A render waits for a free
    worker, within its timeout.
  - `:memory_limit` - the most memory, in bytes, a worker may use, counting what Typst
    caches between renders (the cache is cleared when it takes half of the limit). A render
    that goes over it fails, and its worker is replaced. Defaults to `nil`, for no limit.
  - `:max_renders` - replaces each worker after this many renders, which bounds the memory
    a long-running worker holds on to. Defaults to `nil`, to keep workers for as long as they
    work.

  ## How it works

  Each worker runs `typsty_worker`, a program built from the same code as the NIF, which
  Typsty installs next to it. The pool talks to it through a port. A worker renders one
  document at a time, and keeps Typst's caches and its fonts between renders, like the
  NIF does.

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
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, size: System.schedulers_online(), memory_limit: nil, max_renders: nil])

    size = positive_integer!(opts[:size], :size)
    memory_limit = opts[:memory_limit] && positive_integer!(opts[:memory_limit], :memory_limit)
    max_renders = opts[:max_renders] && positive_integer!(opts[:max_renders], :max_renders)

    pool_state = %{
      executable: executable!(),
      args: if(memory_limit, do: ["--memory-limit", Integer.to_string(memory_limit)], else: []),
      memory_limit: memory_limit,
      max_renders: max_renders,
      size: size
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

  defp positive_integer!(value, _option) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, option) do
    raise ArgumentError, "the #{inspect(option)} option must be a positive integer, got: #{inspect(value)}"
  end

  @doc false
  # Renders in a worker. Takes the arguments of Typsty.Native.render/4 (the pool name
  # aside), and returns what it returns.
  @spec __render__(NimblePool.pool(), String.t(), map(), [{String.t(), binary()}], map()) ::
          {:ok, binary() | [binary()], [Diagnostic.t()]} | {:error, [Diagnostic.t()] | String.t()}
  def __render__(pool, template, variables, files, options) do
    timeout = options.timeout
    deadline = timeout && System.monotonic_time(:millisecond) + timeout

    NimblePool.checkout!(
      pool,
      :render,
      fn {pool_pid, _ref}, worker -> render_in(worker, pool_pid, {template, variables, files, options}, deadline) end,
      timeout || :infinity
    )
  catch
    :exit, {:timeout, {NimblePool, :checkout, _}} ->
      message = "rendering didn't start within the timeout (#{options.timeout} ms): every worker in the pool was busy"
      {:error, [error(message)]}
  end

  defp render_in(%{port: port} = worker, pool_pid, {template, variables, files, options}, deadline) do
    case remaining(deadline) do
      remaining when remaining == :infinity or remaining > 0 ->
        timeout = if remaining == :infinity, do: nil, else: remaining
        request = {:render, template, variables, files, %{options | timeout: timeout}}
        Port.command(port, :erlang.term_to_binary(request))

        port
        |> await(worker, remaining, options.timeout)
        |> give_back(worker, pool_pid)

      _expired ->
        {timed_out(options.timeout), give_back_port(worker, pool_pid)}
    end
  end

  defp await(port, worker, remaining, timeout) do
    wait = if remaining == :infinity, do: :infinity, else: remaining + @grace_period

    receive do
      {^port, {:data, data}} ->
        {:reply, :erlang.binary_to_term(data, [:safe])}

      {^port, {:exit_status, status}} ->
        {:exited, exit_error(status, worker, timeout)}
    after
      wait ->
        # Closing the port ends the worker
        close(port)
        {:exited, timed_out(timeout)}
    end
  end

  defp give_back({:reply, reply}, worker, pool_pid), do: {reply, give_back_port(worker, pool_pid)}

  defp give_back({:exited, error}, %{port: port}, _pool_pid) do
    close(port)
    {error, :remove}
  end

  # The port goes back to the pool with the worker
  defp give_back_port(%{port: port}, pool_pid) do
    Port.connect(port, pool_pid)
    Process.unlink(port)
    :ok
  rescue
    ArgumentError -> :remove
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
    {:error,
     [error("the render used more than the pool's memory limit (#{worker.memory_limit} bytes), and was stopped")]}
  end

  defp exit_error(status, _worker, _timeout) do
    {:error, [error("the render's worker crashed (it exited with status #{status})")]}
  end

  defp timed_out(timeout) do
    {:error, [error("rendering didn't finish within the timeout (#{timeout} ms), and was stopped")]}
  end

  defp error(message), do: %Diagnostic{severity: :error, message: message}

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
  # The port is handed to the process rendering with it, which receives its messages
  def handle_checkout(:render, {pid, _ref}, %{port: port} = worker, pool_state) do
    Port.connect(port, pid)
    {:ok, worker, worker, pool_state}
  end

  @impl NimblePool
  def handle_checkin(:ok, _from, worker, %{max_renders: max_renders} = pool_state) do
    worker = %{worker | renders: worker.renders + 1}

    if max_renders && worker.renders >= max_renders do
      {:remove, :max_renders, pool_state}
    else
      {:ok, worker, pool_state}
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

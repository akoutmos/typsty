defmodule Typsty.PoolProcessesTest do
  # Counts the worker processes the VM has started, and changes the application config, so
  # these tests run on their own
  use ExUnit.Case, async: false

  alias Typsty.Pool

  @moduletag :pool
  @moduletag :unix

  # Pure computation, which only ends when its worker does
  @busy "#let n = 0\n#for i in range(20000) { for j in range(20000) { n += 1 } }\n#n"

  # The OS pids of the workers. The VM starts port programs through its erl_child_setup
  # process, so they're its children.
  defp workers do
    {output, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,comm="])

    processes =
      for line <- String.split(output, "\n", trim: true) do
        [pid, ppid | command] = String.split(line)
        {pid, ppid, Enum.join(command, " ")}
      end

    helpers = for {pid, ppid, command} <- processes, ppid == System.pid(), command =~ "erl_child_setup", do: pid

    for {pid, ppid, command} <- processes, ppid in helpers, command =~ "typsty_worker" do
      pid
    end
    |> Enum.sort()
  end

  # Waits until a worker is checked out: NimblePool keeps its checked out workers with the
  # requests it served
  defp wait_until_busy(pool) do
    assert eventually(fn ->
             pool
             |> :sys.get_state()
             |> Map.fetch!(:requests)
             |> Map.values()
             |> Enum.any?(&match?({_, _, :state, _}, &1))
           end)
  end

  # Waits until the pool's workers have all started. They start in the background, after the
  # pool does, and the worker programs are running before they're ready for renders
  defp wait_until_ready(pool, size) do
    assert eventually(fn ->
             pool |> :sys.get_state() |> Map.fetch!(:resources) |> :queue.len() == size
           end)
  end

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  setup do
    assert eventually(fn -> workers() == [] end)
    :ok
  end

  test "workers are started with the pool, and end with it" do
    pid = start_supervised!({Pool, name: :pool_lifecycle, size: 3})
    assert eventually(fn -> length(workers()) == 3 end)

    stop_supervised!(:pool_lifecycle)
    refute Process.alive?(pid)
    assert eventually(fn -> workers() == [] end)
  end

  test "a worker whose render times out is replaced" do
    start_supervised!({Pool, name: :pool_timeout, size: 2})
    wait_until_ready(:pool_timeout, 2)
    assert length(workers()) == 2
    before = workers()

    assert {:error, _} = Typsty.to_pdf(@busy, %{}, pool: :pool_timeout, timeout: 100)

    assert eventually(fn -> length(workers()) == 2 and workers() != before end)
    assert length(workers() -- before) == 1
  end

  test "a worker is stopped when the process rendering with it exits" do
    start_supervised!({Pool, name: :pool_caller_exits, size: 1})
    assert eventually(fn -> length(workers()) == 1 end)
    [worker] = workers()

    caller = spawn(fn -> Typsty.to_pdf(@busy, %{}, pool: :pool_caller_exits, timeout: :infinity) end)
    wait_until_busy(:pool_caller_exits)
    Process.exit(caller, :kill)

    # The busy worker ends right away, and a new one replaces it
    assert eventually(fn -> match?([new] when new != worker, workers()) end)
    assert {:ok, _pdf} = Typsty.to_pdf("works", %{}, pool: :pool_caller_exits)
  end

  test "workers are replaced after :max_renders renders" do
    start_supervised!({Pool, name: :pool_recycled, size: 1, max_renders: 2})
    assert eventually(fn -> length(workers()) == 1 end)
    [first] = workers()

    assert {:ok, _} = Typsty.to_pdf("1", %{}, pool: :pool_recycled)
    assert workers() == [first]

    assert {:ok, _} = Typsty.to_pdf("2", %{}, pool: :pool_recycled)
    assert eventually(fn -> match?([second] when second != first, workers()) end)
  end

  test "the pool can be set in the config, for every render" do
    start_supervised!({Pool, name: :pool_configured, size: 1})

    Application.put_env(:typsty, :pool, :pool_configured)
    on_exit(fn -> Application.delete_env(:typsty, :pool) end)

    # PDF files can only be read in a pool
    {:ok, pdf} = Typsty.to_pdf("#set page(width: 2cm, height: 2cm)\nA PDF", %{}, pool: nil)
    assert {:ok, _pdf} = Typsty.to_pdf(~S|#image("page.pdf")|, %{}, files: %{"page.pdf" => pdf})
  end
end

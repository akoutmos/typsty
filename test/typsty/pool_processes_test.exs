defmodule Typsty.PoolProcessesTest do
  # Counts the worker processes the VM has started, so these tests run on their own
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
    assert length(workers()) == 3

    stop_supervised!(:pool_lifecycle)
    refute Process.alive?(pid)
    assert eventually(fn -> workers() == [] end)
  end

  test "a worker whose render times out is replaced" do
    start_supervised!({Pool, name: :pool_timeout, size: 2})
    before = workers()

    assert {:error, _} = Typsty.to_pdf(@busy, %{}, pool: :pool_timeout, timeout: 100)

    assert eventually(fn -> length(workers()) == 2 and workers() != before end)
    assert length(workers() -- before) == 1
  end

  test "a worker is stopped when the process rendering with it exits" do
    start_supervised!({Pool, name: :pool_caller_exits, size: 1})
    [worker] = workers()

    caller = spawn(fn -> Typsty.to_pdf(@busy, %{}, pool: :pool_caller_exits, timeout: :infinity) end)
    Process.sleep(200)
    Process.exit(caller, :kill)

    # The busy worker ends right away, and a new one replaces it
    assert eventually(fn -> match?([new] when new != worker, workers()) end)
    assert {:ok, _pdf} = Typsty.to_pdf("works", %{}, pool: :pool_caller_exits)
  end

  test "workers are replaced after :max_renders renders" do
    start_supervised!({Pool, name: :pool_recycled, size: 1, max_renders: 2})
    [first] = workers()

    assert {:ok, _} = Typsty.to_pdf("1", %{}, pool: :pool_recycled)
    assert workers() == [first]

    assert {:ok, _} = Typsty.to_pdf("2", %{}, pool: :pool_recycled)
    assert eventually(fn -> match?([second] when second != first, workers()) end)
  end
end

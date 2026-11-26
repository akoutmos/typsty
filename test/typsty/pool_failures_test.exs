defmodule Typsty.PoolFailuresTest do
  # How a pool handles a worker program that fails: one that can't start, crashes during a
  # render, answers out of step or not at all. The real worker doesn't fail these ways, so
  # pools here run stand-ins (see Typsty.Test.FakeWorker), which are shell scripts
  use ExUnit.Case, async: true

  alias Typsty.Pool
  alias Typsty.RenderError
  alias Typsty.Test.{FakeWorker, Logs}

  @moduletag :pool
  @moduletag :unix
  @moduletag :tmp_dir
  @moduletag :capture_log

  defp start_pool(worker, opts \\ []) do
    name = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
    start_supervised!({Pool, [name: name, size: 1, __executable__: worker] ++ opts})
    name
  end

  defp render(pool, opts \\ []), do: Typsty.to_svg("Hello", %{}, [pool: pool] ++ opts)

  describe "a worker program that" do
    test "answers renders gets them, and keeps them coming", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir))

      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
    end

    test "is from another version of Typsty fails the pool's start", %{tmp_dir: dir} do
      worker = FakeWorker.write!(dir, check: ~s(echo "typsty_worker 0"; exit 0))

      assert_raise RuntimeError, ~r/is from another version of Typsty \(it printed "typsty_worker 0\\n"\)/, fn ->
        Pool.start_link(size: 1, __executable__: worker)
      end
    end

    test "fails its check fails the pool's start, with what it printed", %{tmp_dir: dir} do
      worker = FakeWorker.write!(dir, check: ~s(echo "the fonts are broken"; exit 3))

      assert_raise RuntimeError, ~r/failed to start \(it exited with status 3\): the fonts are broken$/, fn ->
        Pool.start_link(size: 1, __executable__: worker)
      end
    end

    test "doesn't exist fails the pool's start", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")

      assert_raise RuntimeError, "Typsty.Pool can't run its worker program at #{missing}: Erlang error: :enoent", fn ->
        Pool.start_link(size: 1, __executable__: missing)
      end
    end

    test "isn't executable fails the pool's start", %{tmp_dir: dir} do
      worker = FakeWorker.write!(dir, executable: false)

      # Erlang refuses to start it, or it fails to start with EACCES (status 13), depending
      # on the file system (and its access control lists)
      error = assert_raise RuntimeError, fn -> Pool.start_link(size: 1, __executable__: worker) end

      assert Exception.message(error) =~
               ~r/^(Typsty.Pool can't run its worker program at #{worker}: Erlang error: :eacces|Typsty.Pool's worker program at #{worker} failed to start \(it exited with status 13\): )$/
    end

    test "fails to start with a memory limit fails the pool's start", %{tmp_dir: dir} do
      worker = FakeWorker.write!(dir, warm_up: "read_request; exit 3")

      assert_raise RuntimeError, ~r/fake_worker.* failed to start \(it exited with status 3\)$/, fn ->
        Pool.start_link(size: 1, memory_limit: 100_000_000, __executable__: worker)
      end
    end
  end

  describe "a worker that fails to start" do
    test "is logged and started again in the background, and renders wait for it", %{tmp_dir: dir} do
      Logs.forward(~r/a Typsty.Pool worker failed to start/)
      pool = start_pool(FakeWorker.write!(dir, warm_up: "read_request; exit 3"))

      # Once while the pool starts, then again in the background, a second apart rather than in
      # a tight loop
      assert_receive {:log, "a Typsty.Pool worker failed to start (it exited with status 3), and is started again"}
      assert_receive {:log, "a Typsty.Pool worker failed to start (it exited with status 3)"}, 5_000
      started = System.monotonic_time(:millisecond)
      assert_receive {:log, "a Typsty.Pool worker failed to start (it exited with status 3)"}, 5_000
      assert System.monotonic_time(:millisecond) - started >= 900

      assert {:error, %RenderError{reason: :busy}} = render(pool, timeout: 100)
    end

    test "because it answered out of step is started again", %{tmp_dir: dir} do
      Logs.forward(~r/a Typsty.Pool worker failed to start/)
      start_pool(FakeWorker.write!(dir, warm_up: "read_request; printf '\\000\\000\\000\\001x'; wait_for_close"))

      assert_receive {:log, "a Typsty.Pool worker failed to start (it answered out of step), and is started again"}
      assert_receive {:log, "a Typsty.Pool worker failed to start (it answered out of step)"}, 5_000
    end

    test "because its program is gone is started again", %{tmp_dir: dir} do
      Logs.forward(~r/a Typsty.Pool worker failed to start/)

      # It passes its check, and then isn't there to be run
      start_pool(FakeWorker.write!(dir, check: ~s(rm -- "$0"; echo "typsty_worker 1"; exit 0)))

      assert_receive {:log, "a Typsty.Pool worker failed to start (Erlang error: :enoent), and is started again"}
      assert_receive {:log, "a Typsty.Pool worker failed to start (Erlang error: :enoent)"}, 5_000
    end
  end

  describe "a render" do
    test "whose worker exits before it takes the render goes to another, until they've all exited", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: "read_request; exit 7"))

      assert {:error, %RenderError{reason: :crashed, diagnostics: [%{message: "the pool's workers had exited"}]}} =
               render(pool)
    end

    for {code, why} <- [
          {"exit 7", "it exited with status 7"},
          {"exit 87", "it lost track of its requests"},
          {"kill -TERM $$", "it was killed by signal 15"}
        ] do
      test "whose worker crashes fails, saying how (#{why})", %{tmp_dir: dir} do
        pool = start_pool(FakeWorker.write!(dir, then: "read_request; started; " <> unquote(code)))

        assert {:error, %RenderError{reason: :crashed, diagnostics: [%{message: message}]}} = render(pool)
        assert message == "the render's worker crashed (#{unquote(why)})"
      end
    end

    test "whose worker stops it at its timeout or memory limit fails with that reason", %{tmp_dir: dir} do
      timeout = start_pool(FakeWorker.write!(dir, then: "read_request; started; exit 86"))
      assert {:error, %RenderError{reason: :timeout}} = render(timeout, timeout: 5_000)

      memory = start_pool(FakeWorker.write!(dir, then: "read_request; started; exit 85"))

      assert {:error, %RenderError{reason: :memory_limit, diagnostics: [%{message: message}]}} = render(memory)
      assert message =~ "the render used more than the pool's memory limit"
    end

    for {name, code} <- [
          {"isn't in the external term format", "printf '\\000\\000\\000\\003abc'; wait_for_close"},
          {"isn't a result", FakeWorker.printf({:hello, "world"}) <> "; wait_for_close"}
        ] do
      test "whose worker sends a response that #{name} fails, and the worker is replaced", %{tmp_dir: dir} do
        pool = start_pool(FakeWorker.write!(dir, then: "read_request; started; " <> unquote(code)))

        for _attempt <- 1..2 do
          assert {:error, %RenderError{reason: :crashed, diagnostics: [%{message: message}]}} = render(pool)
          assert message == "the render's worker sent a response that couldn't be read"
        end
      end
    end

    test "whose worker exits after its timeout fails as busy, rather than waiting for another worker", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: "read_request; sleep 0.3; exit 7"))

      assert {:error, %RenderError{reason: :busy, diagnostics: [%{message: message}]}} = render(pool, timeout: 100)
      assert message =~ "rendering didn't start within the timeout (100 ms)"
    end

    test "waiting for its worker to take it fails when the pool stops", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: "read_request; wait_for_close"))
      task = Task.async(fn -> render(pool, timeout: 60_000) end)
      wait_until(fn -> Process.info(task.pid, :current_function) == {:current_function, {Pool, :await_start, 6}} end)

      stop_supervised!(pool)

      assert {:error,
              %RenderError{reason: :crashed, diagnostics: [%{message: "the pool stopped before the render started"}]}} =
               Task.await(task)
    end

    test "leaves no messages from its worker behind, even if the worker sends more than its answer", %{tmp_dir: dir} do
      # Written with its answer, so that both arrive together
      extra = Path.join(dir, "extra")
      File.write!(extra, FakeWorker.frame({:ok, ["<svg>extra</svg>"], []}))

      pool =
        start_pool(FakeWorker.write!(dir, then: ~s(read_request; started; cat "$reply" "#{extra}"; wait_for_close)))

      # The extra answer comes here or goes to the pool, depending on when it arrives: either
      # way, the caller doesn't get it, and the worker, which is out of step, is replaced
      for _render <- 1..3 do
        assert render(pool) == {:ok, ["<svg>fake</svg>"]}
        Process.sleep(50)
        assert {:messages, []} = Process.info(self(), :messages)
      end
    end

    test "whose worker doesn't take it is stopped once the timeout passes", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: "read_request; wait_for_close"))

      assert {:error, %RenderError{reason: :timeout, diagnostics: [%{message: message}]}} = render(pool, timeout: 100)
      assert message == "rendering didn't finish within the timeout (100 ms), and its worker was stopped"
    end

    test "whose worker takes it but never answers is stopped once the timeout passes", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: "read_request; started; wait_for_close"))

      {elapsed, result} = :timer.tc(fn -> render(pool, timeout: 100) end, :millisecond)
      assert {:error, %RenderError{reason: :timeout}} = result

      # The worker gets a grace period to stop the render itself
      assert elapsed >= 1_100
    end

    test "whose worker exits after answering is answered, and the next one gets a new worker", %{tmp_dir: dir} do
      pool = start_pool(FakeWorker.write!(dir, then: ~s(read_request; started; cat "$reply"; exit 0)))

      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
    end

    test "gets the warnings its worker answers with, pointing at the template", %{tmp_dir: dir} do
      warning = %Typsty.Diagnostic{severity: :warning, message: "unknown font family: x", line: 2, column: 3}
      pool = start_pool(FakeWorker.write!(dir, reply: {:ok, ["<svg/>"], [warning]}))

      :telemetry.attach("fake-#{inspect(self())}", [:typsty, :render, :stop], &__MODULE__.send_stop/4, self())
      on_exit(fn -> :telemetry.detach("fake-#{inspect(self())}") end)

      assert {:ok, ["<svg/>"]} = Typsty.to_svg("Hello", %{}, pool: pool)

      assert_receive {:stop,
                      %{template: %{source: "Hello"}, diagnostics: [%{message: "unknown font family: x", line: 2}]}}
    end
  end

  describe "an idle worker" do
    test "that sends data it wasn't asked for is replaced", %{tmp_dir: dir} do
      Logs.forward(~r/sent data it wasn't asked for/)
      start_pool(FakeWorker.write!(dir, then: "sleep 0.2; printf '\\000\\000\\000\\001x'; wait_for_close"))

      assert_receive {:log, "an idle Typsty.Pool worker sent data it wasn't asked for, and is replaced"}, 5_000
    end

    test "that exits is replaced, with a warning unless it retired itself", %{tmp_dir: dir} do
      Logs.forward(~r/an idle Typsty.Pool worker exited/)
      start_pool(FakeWorker.write!(dir, then: "sleep 0.2; exit 5"))
      assert_receive {:log, "an idle Typsty.Pool worker exited (it exited with status 5), and is replaced"}, 5_000

      # A worker exits with status 0 when it retires (with its table of file paths nearly
      # full, say), which isn't worth a warning. The replacement answers renders
      pool = start_pool(FakeWorker.write!(dir, then: ~s(read_request; started; cat "$reply"; exit 0)))
      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
      refute_receive {:log, "an idle Typsty.Pool worker exited (it exited with status 0)" <> _}, 300
      assert render(pool) == {:ok, ["<svg>fake</svg>"]}
    end
  end

  @doc false
  def send_stop(_event, _measurements, metadata, test), do: send(test, {:stop, metadata})

  defp wait_until(condition, tries \\ 500) do
    cond do
      condition.() -> :ok
      tries == 0 -> flunk("the condition never held")
      true -> Process.sleep(10) && wait_until(condition, tries - 1)
    end
  end
end

defmodule Typsty.Test.Logs do
  @moduledoc false
  # Forwards the messages logged while a test runs that match a pattern to the test's
  # process, as {:log, message}: logs from the pool's processes, say, which a test can then
  # wait for

  # With `time: true`, the messages are {:log, message, time}, with the time (in
  # microseconds, from the logger) the message was logged at

  def forward(pattern, opts \\ []) do
    id = :"typsty_test_logs_#{System.unique_integer([:positive])}"
    config = %{pid: self(), pattern: pattern, time?: Keyword.get(opts, :time, false)}
    :ok = :logger.add_handler(id, __MODULE__, %{config: config})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
  end

  @doc false
  def log(%{msg: msg, meta: meta}, %{config: %{pid: pid, pattern: pattern, time?: time?}}) do
    message =
      case msg do
        {:string, chardata} -> IO.chardata_to_string(chardata)
        {:report, report} -> inspect(report)
        {format, args} -> format |> :io_lib.format(args) |> IO.chardata_to_string()
      end

    cond do
      not (message =~ pattern) -> :ok
      time? -> send(pid, {:log, message, meta.time})
      true -> send(pid, {:log, message})
    end
  end
end

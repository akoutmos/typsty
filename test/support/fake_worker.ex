defmodule Typsty.Test.FakeWorker do
  @moduledoc false
  # Stand-ins for the pool's worker program, as POSIX shell scripts, which fail in ways the
  # real worker doesn't: they answer --check, then a warm-up render, then behave as told.
  #
  # Requests are frames: a 4-byte length, then the request in the external term format.
  # The worker acknowledges each one with the atom `started`, then sends its result.

  @doc """
  Writes a fake worker into the directory and returns its path. Options:

  - `:check` - shell code for `--check` (by default, it prints the protocol version)
  - `:warm_up` - shell code for the warm-up render (by default, it answers it)
  - `:then` - shell code for what comes after (by default, it answers every render with
    `reply`)
  - `:reply` - what renders are answered with
  - `:executable` - whether the script can be run (true by default)
  """
  def write!(dir, opts \\ []) do
    path = Path.join(dir, "fake_worker_#{System.unique_integer([:positive])}")
    reply = Path.join(dir, "reply_#{System.unique_integer([:positive])}")
    File.write!(reply, frame(Keyword.get(opts, :reply, {:ok, ["<svg>fake</svg>"], []})))

    File.write!(path, """
    #!/bin/sh
    reply="#{reply}"

    if [ "$1" = "--check" ]; then
      #{Keyword.get(opts, :check, ~s(echo "typsty_worker 1"; exit 0))}
    fi

    # Reads a request: its length, then that many bytes. Ends at the end of the input
    read_request() {
      length=$(dd bs=1 count=4 2>/dev/null | od -An -tu1 | awk 'NF == 4 { print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')
      [ -n "$length" ] || exit 0
      dd bs=1 count="$length" of=/dev/null 2>/dev/null
    }

    # Acknowledges a request: `started`, as a UTF-8 atom
    started() { printf '\\000\\000\\000\\012\\203\\167\\007started'; }

    # Waits until the pool closes the port
    wait_for_close() { dd bs=1 count=1 of=/dev/null 2>/dev/null; exit 0; }

    #{Keyword.get(opts, :warm_up, ~s(read_request; started; cat "$reply"))}

    #{Keyword.get(opts, :then, ~s(while true; do read_request; started; cat "$reply"; done))}
    """)

    File.chmod!(path, if(Keyword.get(opts, :executable, true), do: 0o755, else: 0o644))
    path
  end

  @doc "A frame with the term, as a worker sends it."
  def frame(term) when not is_binary(term), do: frame(:erlang.term_to_binary(term))
  def frame(binary), do: <<byte_size(binary)::32, binary::binary>>

  @doc "Shell code that prints a frame with the term, as a worker sends it."
  def printf(term) do
    octal = for <<byte <- frame(term)>>, into: "", do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
    "printf '#{octal}'"
  end
end

defmodule Typsty.Test.Logs do
  @moduledoc false
  # Forwards the messages logged while a test runs that match a pattern to the test's
  # process, as {:log, message}: logs from the pool's processes, say, which a test can then
  # wait for

  def forward(pattern) do
    id = :"typsty_test_logs_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: self(), pattern: pattern}})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
  end

  @doc false
  def log(%{msg: msg}, %{config: %{pid: pid, pattern: pattern}}) do
    message =
      case msg do
        {:string, chardata} -> IO.chardata_to_string(chardata)
        {:report, report} -> inspect(report)
        {format, args} -> format |> :io_lib.format(args) |> IO.chardata_to_string()
      end

    if message =~ pattern, do: send(pid, {:log, message})
  end
end

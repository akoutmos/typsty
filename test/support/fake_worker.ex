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
    `reply`). The script defines `read_request`, `started` (which acknowledges a request),
    `answer` (which sends `reply`) and `wait_for_close`
  - `:reply` - what renders are answered with
  - `:executable` - whether the script can be run (true by default)
  - `:pid_file` - a file it writes its OS pid to

  The script's standard error goes nowhere, so that its complaints about writing to a
  closed port don't end up in the tests' output (and so that a script the pool left behind
  doesn't hold the VM's standard error open).
  """
  def write!(dir, opts \\ []) do
    path = Path.join(dir, "fake_worker_#{System.unique_integer([:positive])}")
    reply = Path.join(dir, "reply_#{System.unique_integer([:positive])}")
    File.write!(reply, frame(Keyword.get(opts, :reply, {:ok, ["<svg>fake</svg>"], []})))

    pid_file = if opts[:pid_file], do: ~s(echo $$ > "#{opts[:pid_file]}"), else: ""

    File.write!(path, """
    #!/bin/sh
    exec 2>/dev/null
    reply="#{reply}"
    #{pid_file}

    if [ "$1" = "--check" ]; then
      #{Keyword.get(opts, :check, ~s(echo "typsty_worker 1"; exit 0))}
    fi

    # Reads a request: its length, then that many bytes. Ends at the end of the input
    read_request() {
      length=$(dd bs=1 count=4 2>/dev/null | od -An -tu1 | awk 'NF == 4 { print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')
      [ -n "$length" ] || exit 0
      dd bs=1 count="$length" of=/dev/null 2>/dev/null
    }

    # Acknowledges a request: `started`, as a UTF-8 atom. The VM ignores SIGPIPE, as does
    # what it starts, so writing to a closed port fails rather than ending the script: a
    # write that fails ends it, which ends a script left behind once the VM is gone
    started() { printf '\\000\\000\\000\\012\\203\\167\\007started' || exit 0; }

    # Answers a request with `reply`
    answer() { cat "$reply" || exit 0; }

    # Waits until the pool closes the port
    wait_for_close() { dd bs=1 count=1 of=/dev/null 2>/dev/null; exit 0; }

    #{Keyword.get(opts, :warm_up, "read_request; started; answer")}

    #{Keyword.get(opts, :then, "while true; do read_request; started; answer; done")}
    """)

    File.chmod!(path, if(Keyword.get(opts, :executable, true), do: 0o755, else: 0o644))
    path
  end

  @doc "A frame with the term, as a worker sends it."
  def frame(term) when not is_binary(term), do: frame(:erlang.term_to_binary(term))
  def frame(binary), do: <<byte_size(binary)::32, binary::binary>>

  @doc "Shell code that prints a frame with the term, as a worker sends it (or ends the script)."
  def printf(term) do
    octal = for <<byte <- frame(term)>>, into: "", do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
    "{ printf '#{octal}' || exit 0; }"
  end
end

defmodule Typsty.Test.HTTPServer do
  @moduledoc false
  # A minimal HTTP/1.1 server on localhost, for the package downloader's tests, which can
  # stand in for the registry or for a proxy. Each request is sent to the test process as
  # {:request, port, method, target, headers} (the headers' names in lowercase), and
  # answered with what the handler returns for it:
  #
  # - {status, body}: the body, with its length
  # - {:repeat, status, chunk, count}: the chunk, count times, with their whole length
  # - :close: no answer, the connection is closed

  def start(handler) do
    test = self()
    ref = make_ref()

    spawn_link(fn ->
      # A backlog for many connections at once (the default is 5), which a test's downloads
      # can open while this is busy serving others
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, backlog: 128])
      {:ok, port} = :inet.port(listen)
      send(test, {ref, port})
      accept(listen, port, handler, test)
    end)

    receive do
      {^ref, port} -> %{port: port, url: "http://127.0.0.1:#{port}"}
    end
  end

  @doc "A port on localhost that nothing listens on."
  def closed_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  defp accept(listen, port, handler, test) do
    {:ok, socket} = :gen_tcp.accept(listen)

    pid =
      spawn(fn ->
        receive do
          :serve -> serve(socket, port, handler, test)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :serve)
    accept(listen, port, handler, test)
  end

  defp serve(socket, port, handler, test) do
    with {:ok, head} <- read_head(socket, "") do
      [request_line | header_lines] = String.split(head, "\r\n", trim: true)
      [method, target, _version] = String.split(request_line, " ", parts: 3)

      headers =
        Map.new(header_lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      send(test, {:request, port, method, target, headers})
      respond(socket, handler.(method, target, headers))
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, received) do
    case :binary.split(received, "\r\n\r\n") do
      [head, _body] -> {:ok, head}
      [_partial] -> with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: read_head(socket, received <> data)
    end
  end

  defp respond(socket, {status, body}) do
    :gen_tcp.send(socket, [head(status, byte_size(body)), body])
  end

  # The client may stop reading partway, which ends the response
  defp respond(socket, {:repeat, status, chunk, count}) do
    with :ok <- :gen_tcp.send(socket, head(status, byte_size(chunk) * count)) do
      send_chunks(socket, chunk, count)
    end
  end

  defp respond(_socket, :close), do: :ok

  defp send_chunks(_socket, _chunk, 0), do: :ok

  defp send_chunks(socket, chunk, count) do
    with :ok <- :gen_tcp.send(socket, chunk), do: send_chunks(socket, chunk, count - 1)
  end

  defp head(status, length) do
    "HTTP/1.1 #{status} #{reason(status)}\r\ncontent-length: #{length}\r\nconnection: close\r\n\r\n"
  end

  defp reason(200), do: "OK"
  defp reason(403), do: "Forbidden"
  defp reason(404), do: "Not Found"
  defp reason(407), do: "Proxy Authentication Required"
  defp reason(500), do: "Internal Server Error"
  defp reason(503), do: "Service Unavailable"
end

defmodule PpClient.Test.UpgradeRequest do
  @moduledoc """
  Captures the raw HTTP/1.1 upgrade request `PpClient.WSClient` puts on the
  wire, so tests assert on the bytes sent rather than on the header list we
  meant to send. Mint rewrites header casing and both Mint and Mint.WebSocket
  inject headers of their own, so the difference matters.
  """

  @doc """
  Starts a `PpClient.WSClient` against a throwaway local listener and returns
  `{request_line, headers}` with header names exactly as they went out.
  """
  def capture(setting_overrides \\ %{}) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    setting =
      Map.merge(
        %{uri: "ws://localhost:#{port}/ws", type: "plain"},
        setting_overrides
      )

    parent = self()

    owner =
      spawn(fn ->
        case PpClient.WSClient.start_link({:tcp, "example.com", 443}, setting, parent) do
          {:ok, pid} -> send(parent, {:client, pid})
          _ -> :ok
        end

        # Stay alive so the linked client is not torn down mid-handshake.
        Process.sleep(:infinity)
      end)

    try do
      {:ok, sock} = :gen_tcp.accept(lsock, 5000)
      {:ok, data} = :gen_tcp.recv(sock, 0, 5000)

      # The request is already captured, so shut the client down before closing
      # the socket rather than leaving it to notice the close and tell its owner.
      stop(owner)
      :gen_tcp.close(sock)
      parse(data)
    after
      stop(owner)
      :gen_tcp.close(lsock)
    end
  end

  defp stop(owner) do
    receive do
      {:client, pid} -> shutdown(pid)
    after
      0 -> :ok
    end

    shutdown(owner)
  end

  defp shutdown(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 -> :ok
      end
    end
  end

  defp parse(data) do
    [request_line | header_lines] =
      data
      |> String.split("\r\n")
      |> Enum.reject(&(&1 == ""))

    headers =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {name, value}
      end)

    {request_line, headers}
  end

  @doc "Header names in wire order, casing preserved."
  def names({_request_line, headers}), do: Enum.map(headers, &elem(&1, 0))

  @doc "Fetches a header value by case-insensitive name."
  def get({_request_line, headers}, name) do
    target = String.downcase(name)

    Enum.find_value(headers, fn {n, v} ->
      if String.downcase(n) == target, do: v
    end)
  end
end

defmodule PpClient do
  def main(_) do
    start()
    IO.puts("Client started.")

    receive do
      :stop -> :stop
    end
  end

  def start, do: Application.ensure_started(:pp_client)
  def stop, do: System.halt(0)
end

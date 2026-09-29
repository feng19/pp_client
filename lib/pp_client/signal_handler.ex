defmodule PpClient.SignalHandler do
  @moduledoc false
  # Replaces the default `:erl_signal_server` handler so every termination signal
  # (SIGTERM, SIGHUP, SIGQUIT) goes through System.stop/0. That shuts the
  # supervision tree down in order, which is what runs
  # `PpClient.CmdPortManager.terminate/2` and stops the commands it started.
  @behaviour :gen_event
  require Logger

  @stop_signals [:sigterm, :sighup, :sigquit]

  def install do
    Enum.each(@stop_signals, &:os.set_signal(&1, :handle))
    :gen_event.swap_handler(:erl_signal_server, {:erl_signal_handler, []}, {__MODULE__, []})
    :ok
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_event(signal, state) when signal in @stop_signals do
    Logger.warning("received #{signal}, shutting down...")
    System.stop()
    {:ok, state}
  end

  def handle_event(signal, state) do
    Logger.info("ignored signal: #{inspect(signal)}")
    {:ok, state}
  end

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}
end

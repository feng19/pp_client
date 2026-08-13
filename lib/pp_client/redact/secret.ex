defmodule PpClient.Redact.Secret do
  @moduledoc """
  A credential that keeps itself out of `inspect/1` output.

  For a value that has to stay usable where it is held: a LiveView's assigns are
  written to the log whole when the process crashes, but the form still has to
  render the password it is editing. Wrapping keeps the value reachable through
  `PpClient.Redact.reveal/1` and unreadable through everything else.

  There is deliberately no `String.Chars` implementation. Interpolating a secret
  by accident is the mistake this module exists to catch, so it raises instead of
  quietly printing.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  @doc "Wraps `value`, or returns it untouched if it is already wrapped."
  @spec new(term()) :: t()
  def new(%__MODULE__{} = secret), do: secret
  def new(value), do: %__MODULE__{value: value}

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#PpClient.Redact.Secret<redacted>"
  end
end

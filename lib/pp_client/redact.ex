defmodule PpClient.Redact do
  @moduledoc """
  Strips proxy credentials out of anything that will be inspected.

  A process that dies abnormally has its whole state written to the log, and a
  tunnel carries the credential it authenticates with: the cf-workers password,
  the exps encryption key. The same values ride along in profiles, so a stray
  `inspect/1` on a server or a route prints them too.

  Nothing here protects a value that is still in use — it produces a copy safe to
  print. Whatever needs the real credential must hold it separately.
  """

  alias PpClient.Redact.Secret

  @secret_keys [:password, :encrypt_key]
  @secret_param_keys Enum.map(@secret_keys, &Atom.to_string/1)
  @secret_headers ["authorization", "proxy-authorization"]

  @doc """
  Replaces every secret value in a server setting with `:redacted`.

  Takes the map or keyword list that settings come in as and gives back the same
  shape, so a redacted copy still reads like the original. The marker is an atom
  on purpose: code that mistakes the copy for the real setting trips over the
  next `is_binary/1` instead of quietly authenticating with a placeholder.
  """
  @spec setting(map()) :: map()
  @spec setting(keyword()) :: keyword()
  def setting(setting) when is_map(setting), do: Map.new(setting, &redact_pair/1)
  def setting(setting) when is_list(setting), do: Enum.map(setting, &redact_pair/1)

  defp redact_pair({key, _value}) when key in @secret_keys, do: {key, :redacted}
  defp redact_pair(pair), do: pair

  @doc """
  Wraps the secrets in a form's params so they survive being held but not printed.

  Takes the string-keyed map a form field set comes in as and returns it with the
  credentials wrapped in `PpClient.Redact.Secret`. Read them back with `reveal/1`
  wherever the real value is needed — rendering the input, casting a changeset.

  Use this where the value is still needed after it lands in state. Where it is
  not, `params/1` throws it away instead.
  """
  @spec form_params(map()) :: map()
  def form_params(params) when is_map(params) do
    Map.new(params, fn
      # An empty field has nothing to hide, and wrapping it would only make the
      # blank the form renders harder to read.
      {key, value} when key in @secret_param_keys and is_binary(value) and value != "" ->
        {key, Secret.new(value)}

      pair ->
        pair
    end)
  end

  @doc """
  Reads a value back out, whether or not it was wrapped by `form_params/1`.
  """
  @spec reveal(term()) :: term()
  def reveal(%Secret{value: value}), do: value
  def reveal(value), do: value

  @doc """
  Blanks every secret in a string-keyed param map, however deeply nested.

  For the copies of submitted params that are only ever read back to re-render a
  form field this application does not render — nothing needs the value, so it
  does not keep it.
  """
  @spec params(map()) :: map()
  def params(params) when is_map(params) do
    Map.new(params, fn
      {key, _value} when key in @secret_param_keys -> {key, "[REDACTED]"}
      {key, value} when is_map(value) and not is_struct(value) -> {key, params(value)}
      pair -> pair
    end)
  end

  @doc """
  Blanks the value of every credential-bearing request header.

  Values stay binaries so the result is still a usable header list rather than
  something that only survives being printed.
  """
  @spec headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def headers(headers) do
    Enum.map(headers, fn {name, value} ->
      if String.downcase(name) in @secret_headers do
        {name, "[REDACTED]"}
      else
        {name, value}
      end
    end)
  end
end

defmodule PpClient.Condition do
  @moduledoc """
  Struct representing a proxy condition

  https://github.com/FelisCatus/SwitchyOmega/wiki/SwitchyOmega-conditions-format

  ```
  [SwitchyOmega Conditions]
  ; A line starting with semi-colon is a comment line, ignored by the parser.
  ; When you edit rules using the table-based visual editor in SwitchyOmega options page, the original
  ; formatting, including the comments, is NOT preserved.

  ; If you want to stick a note associated with the rule, use a @rule directive above each rule.
  ; Such notes will be picked up by the visual editor and re-emitted when you publish in text format.
  @note This is a HostWildcardCondition matching *.example.com.
  *.example.com

  ; This is a UrlWildcardCondition.
  UrlWildcard: https://*.google.com/*

  ; You can also write UW for short, representing the same UrlWildcardCondition.
  UW: https://*.google.com/*

  ; This is a UrlRegexCondition. Most types of conditions can be represented with :ConditionType pattern
  UrlRegex: ^https://www\.example\.(net|org)/

  ; Conditions can be prefixed with ! to make it exclusive. Any requests matching an exclusive condition will
  ; use the "default profile" instead of "match profile".
  @note Use the default profile for internal stuff at my company
  !*.internal.example.org

  ; Conditions are matched against the request in top-down order.
  ; The process stops as soon as the first matching condition is applied.

  ; If no other condition matches, the "default profile" will be used.
  ```
  """
  require Logger

  defstruct [:id, :condition, :profile_name, :enabled]

  @type t :: %__MODULE__{
          id: non_neg_integer() | nil,
          condition: Regex.t() | :all,
          profile_name: String.t(),
          enabled: boolean()
        }

  def parse_conditions(text) do
    conditions =
      text
      |> String.split("\n", trim: true)
      |> Stream.reject(fn
        "" -> true
        "[" <> _ -> true
        ";" <> _ -> true
        "!" <> _ -> true
        "@note " <> _ -> true
        "@with " <> _ -> true
        _ -> false
      end)
      |> Enum.reduce([], fn
        "* +" <> profile, acc ->
          [%__MODULE__{condition: :all, profile_name: profile, enabled: true} | acc]

        line, acc ->
          [pattern, "+" <> profile] = String.split(line, " ", trim: true)

          case pattern_to_regex(pattern) do
            {:ok, regex} ->
              condition = %__MODULE__{
                condition: regex,
                profile_name: profile,
                enabled: true
              }

              [condition | acc]

            {:error, reason} ->
              Logger.warning("lien: #{line}, parse error: #{inspect(reason)}")
              acc
          end
      end)
      |> Enum.reverse()

    {:ok, conditions}
  end

  def pattern_to_regex(pattern) do
    regex_pattern =
      pattern
      |> String.trim()
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> String.replace("?", ".")

    Regex.compile("^" <> regex_pattern <> "$")
  end
end

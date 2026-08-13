defmodule PpClient.Schemas.ConditionSchema do
  @moduledoc """
  Schema for Condition form validation and conversion
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PpClient.Condition

  @primary_key false
  embedded_schema do
    field :id, :integer
    field :pattern, :string
    field :profile_name, :string
    field :enabled, :boolean, default: true
  end

  @doc """
  Changeset for condition validation
  """
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :pattern, :profile_name, :enabled])
    |> validate_required([:pattern, :profile_name])
    |> validate_length(:pattern, min: 1, max: 500)
    |> validate_length(:profile_name, min: 1, max: 100)
    |> validate_pattern()
  end

  defp validate_pattern(changeset) do
    pattern = get_field(changeset, :pattern)

    if pattern do
      case Condition.pattern_to_regex(pattern) do
        {:ok, _regex} ->
          changeset

        {:error, _reason} ->
          add_error(changeset, :pattern, "invalid match pattern")
      end
    else
      changeset
    end
  end

  @doc """
  Convert ConditionSchema to Condition struct
  """
  def to_condition(%__MODULE__{} = schema) do
    condition_value =
      if schema.pattern == "*" do
        :all
      else
        case Condition.pattern_to_regex(schema.pattern) do
          {:ok, regex} -> regex
          {:error, _} -> :all
        end
      end

    %Condition{
      id: schema.id,
      condition: condition_value,
      profile_name: schema.profile_name,
      enabled: schema.enabled
    }
  end

  @doc """
  Convert Condition to ConditionSchema
  """
  def from_condition(%Condition{} = condition) do
    pattern =
      case condition.condition do
        :all -> "*"
        %Regex{} = regex -> regex_to_pattern(regex)
      end

    %__MODULE__{
      id: condition.id,
      pattern: pattern,
      profile_name: condition.profile_name,
      enabled: condition.enabled
    }
  end

  defp regex_to_pattern(%Regex{source: source}) do
    # Use temporary placeholders so escaped dots and wildcards are handled correctly
    source
    |> String.trim_leading("^")
    |> String.trim_trailing("$")
    |> String.replace("\\.", "<<<DOT>>>")
    |> String.replace(".*", "*")
    |> String.replace(".", "?")
    |> String.replace("<<<DOT>>>", ".")
  end
end

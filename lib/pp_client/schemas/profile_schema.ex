defmodule PpClient.Schemas.ProfileSchema do
  @moduledoc """
  Schema for Profile form validation and conversion

  A profile only names the servers it routes through — the definitions belong to
  `PpClient.Schemas.ServerSchema` and the Servers page — so nothing here carries
  a credential.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PpClient.ProxyProfile
  alias PpClient.ServerManager

  @primary_key false
  embedded_schema do
    field :name, :string
    field :type, Ecto.Enum, values: [:direct, :remote], default: :remote
    field :enabled, :boolean, default: true
    field :servers, {:array, :string}, default: []
  end

  @doc """
  Changeset for profile validation
  """
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:name, :type, :enabled, :servers])
    |> validate_required([:name, :type])
    |> validate_length(:name, min: 1, max: 100)
    |> drop_blank_servers()
    |> validate_servers_exist()
    |> validate_remote_servers()
  end

  # The form posts an empty `servers[]` alongside the multi-select so clearing
  # every option still sends the key — see the hidden input in the template.
  # That blank is a marker, not a choice.
  defp drop_blank_servers(changeset) do
    case get_change(changeset, :servers) do
      nil -> changeset
      servers -> put_change(changeset, :servers, Enum.reject(servers, &(&1 == "")))
    end
  end

  defp validate_servers_exist(changeset) do
    case get_field(changeset, :servers) do
      servers when is_list(servers) ->
        case Enum.reject(servers, &ServerManager.exists?/1) do
          [] -> changeset
          unknown -> add_error(changeset, :servers, "unknown server: #{Enum.join(unknown, ", ")}")
        end

      _ ->
        changeset
    end
  end

  # Gated on the field having been submitted rather than on `changeset.action`:
  # `Ecto.Changeset.apply_action/2` only stamps the action on its error branch,
  # after the validations have already run, so an action gate here never fires.
  # The form always posts `servers[]`, so the key is present from the first
  # change onwards but absent on the untouched new-profile form.
  defp validate_remote_servers(changeset) do
    if Map.has_key?(changeset.params, "servers") do
      type = get_field(changeset, :type)
      servers = get_field(changeset, :servers)

      if type == :remote and (is_nil(servers) or servers == []) do
        add_error(changeset, :servers, "remote proxy profile must have at least one server")
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc """
  Convert ProfileSchema to ProxyProfile struct
  """
  def to_profile(%__MODULE__{} = schema) do
    %ProxyProfile{
      name: schema.name,
      type: schema.type,
      enabled: schema.enabled,
      servers: schema.servers || []
    }
  end

  @doc """
  Convert ProxyProfile to ProfileSchema
  """
  def from_profile(%ProxyProfile{} = profile) do
    %__MODULE__{
      name: profile.name,
      type: profile.type,
      enabled: profile.enabled,
      servers: profile.servers || []
    }
  end
end

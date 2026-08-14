defmodule PpClient.Config do
  @moduledoc """
  The `pp.exs` file: loading one into the runtime tables, and writing the runtime
  tables back out as one.

  The file is an Elixir script whose last expression is a map, and it is the only
  durable copy of the configuration — everything the admin pages edit lives in
  ETS and is gone at the next boot. `dump/1` is the way back out: it renders the
  tables as a file `build/1` accepts again, so a session's edits can be saved
  rather than retyped, and `replace/1` takes such a file and swaps the whole
  configuration for what is in it.

  `build/1` constructs every entity before `insert!/1` writes any of them, so a
  file naming a server that does not exist leaves the running tables untouched
  instead of half-replaced. That ordering is what makes `replace/1` safe to point
  at a file someone just uploaded.
  """
  require Logger

  alias PpClient.{
    Cache,
    Condition,
    ConditionManager,
    DnsRecord,
    DnsRecordManager,
    Endpoint,
    EndpointManager,
    ProfileManager,
    ProxyProfile,
    ProxyServer,
    Redact,
    ServerManager
  }

  alias PpClient.Schemas.ConditionSchema

  @tables [:endpoints, :servers, :profiles, :conditions, :dns_records]

  # A bulk write goes around the managers the admin pages broadcast from, so an
  # import has to announce itself or every open page keeps rendering the
  # configuration it just replaced.
  @topics [
    {"endpoints", :endpoint_updated},
    {"servers", :server_updated},
    {"profiles", :profile_updated},
    {"conditions", :condition_updated},
    {"dns_records", :dns_record_updated}
  ]

  @doc """
  The `web:` section of the configuration that is currently loaded.

  It is the one section with nothing behind it in ETS — the options went into
  `PpClientWeb.Endpoint`'s child spec at boot and cannot be read back out of it,
  because `config/*.exs` overrides them. Kept here so `dump/1` can write the
  section back out as it came in.
  """
  @spec web() :: map() | keyword() | nil
  def web, do: Application.get_env(:pp_client, :web_config)

  @spec put_web(map() | keyword() | nil) :: :ok
  def put_web(web), do: Application.put_env(:pp_client, :web_config, web)

  ## Reading

  @doc """
  Evaluates a config file, without applying it.
  """
  @spec eval_file(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def eval_file(path) do
    if File.exists?(path) do
      path |> File.read!() |> eval_string(path)
    else
      {:error, "no such file: #{path}"}
    end
  end

  @doc """
  Evaluates config source, without applying it.

  A config is arbitrary Elixir — `pp.exs` reaches for `System.fetch_env!/1` — so
  anything it raises, throws or exits with is turned into a message here rather
  than left to take the caller down. The result has to be a map; `{:error, _}`
  covers a file that is valid Elixir but is not a configuration.
  """
  @spec eval_string(String.t(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  def eval_string(source, path \\ "pp.exs") when is_binary(source) do
    case Code.eval_string(source, [], file: path) do
      {config, _binding} when is_map(config) -> {:ok, config}
      {other, _binding} -> {:error, "expected the file to end in a map, got: #{brief(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, "#{kind}: #{brief(value)}"}
  end

  ## Applying

  @doc """
  Builds every entity a config describes, touching no table.

  Same validation the boot path runs, with the failure returned instead of
  raised — the caller can report an uploaded file as bad and keep serving the
  configuration it already has.
  """
  @spec build(term()) :: {:ok, map()} | {:error, String.t()}
  def build(config) when is_map(config) do
    {:ok, build!(config)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def build(other), do: {:error, "expected a map, got: #{brief(other)}"}

  @doc """
  `build/1`, raising on the first entity that does not hold up.
  """
  @spec build!(map()) :: map()
  def build!(config) when is_map(config) do
    servers = build_servers(config)

    %{
      web: config[:web],
      endpoints: Enum.map(config[:endpoints] || [], &Endpoint.new/1),
      servers: servers,
      profiles: build_profiles(config, servers),
      conditions: Condition.parse_conditions(config[:conditions] || ""),
      dns: Enum.map(config[:dns] || [], &DnsRecord.new/1)
    }
  end

  @doc """
  Builds a config and writes it into the tables, raising if it does not hold up.

  The boot path. Nothing is cleared first, because at boot there is nothing to
  clear, and a bad config should stop the node rather than start it half
  configured.
  """
  @spec load!(map()) :: :ok
  def load!(config), do: config |> build!() |> insert!()

  @doc """
  Writes an already-built config into the tables.
  """
  @spec insert!(map()) :: :ok
  def insert!(built) do
    put_web(built.web)
    insert(:endpoints, built.endpoints, & &1.port)
    insert(:servers, built.servers, & &1.name)
    insert(:profiles, built.profiles, & &1.name)
    insert(:conditions, built.conditions, & &1.id)
    insert(:dns_records, built.dns, & &1.domain)
    :ok
  end

  @doc """
  Swaps the whole configuration for the one a config describes.

  Every table this config file covers is emptied and rebuilt, so an entry that
  the file leaves out is gone afterwards — importing a file is meant to put the
  client in the state that file describes, not to merge into whatever the
  session had accumulated.

  The listeners come down and back up with it. `:failed_endpoints` in the
  summary holds the ports that would not bind, which is the one part of an
  import that can fail after the config itself has been accepted.

  The `web:` section is stored for the next `dump/1` but not applied: the admin
  UI is served by the endpoint it configures, and the request asking for the
  import is riding on it.
  """
  @spec replace(term()) :: {:ok, map()} | {:error, String.t()}
  def replace(config) do
    with {:ok, built} <- build(config) do
      {:ok, swap(built)}
    end
  end

  defp swap(built) do
    # The ports are held by the listeners, so they have to come down before the
    # table describing them is emptied — after that there is nothing left to name
    # the child to terminate.
    Enum.each(EndpointManager.all_endpoints(), &EndpointManager.stop/1)
    Enum.each(@tables, &:ets.delete_all_objects/1)

    insert!(built)

    # Both managers hold state outside their table: the id conditions are keyed
    # by, and the direct profile every boot is guaranteed to have.
    ProfileManager.ensure_direct()
    ConditionManager.resync()

    failed = start_endpoints(built.endpoints)
    Cache.refresh()
    notify()

    Logger.info("Replaced the configuration with an imported one")

    %{
      endpoints: length(built.endpoints),
      servers: length(built.servers),
      profiles: length(built.profiles),
      conditions: length(built.conditions),
      dns: length(built.dns),
      failed_endpoints: failed
    }
  end

  defp insert(table, entities, key) do
    :ets.insert(table, Enum.map(entities, &{key.(&1), &1}))
  end

  # `servers:` is a keyword list, so the atom key is the server's name.
  defp build_servers(config) do
    Enum.map(config[:servers] || [], fn {key, attrs} ->
      ProxyServer.new(Map.put(attrs, :name, to_string(key)))
    end)
  end

  # Profiles refer to servers by the key they were declared under. The reference
  # is kept as-is rather than resolved — it is checked here only so a typo fails
  # with the profile and the bad name in the message, instead of turning into a
  # silently unroutable profile later on.
  defp build_profiles(config, servers) do
    names = MapSet.new(servers, & &1.name)

    Enum.map(config[:profiles] || [], fn %{servers: referenced} = profile ->
      # Deduplicated because a name listed twice would double that server's odds
      # in the random pick, which is never what a repeated entry means.
      referenced = referenced |> Enum.map(&to_string/1) |> Enum.uniq()
      Enum.each(referenced, &validate_server_reference!(profile, &1, names))
      ProxyProfile.new(%{profile | servers: referenced})
    end)
  end

  defp validate_server_reference!(profile, name, names) do
    unless MapSet.member?(names, name) do
      raise "Profile #{inspect(profile[:name])} refers to unknown server #{inspect(name)}"
    end
  end

  defp start_endpoints(endpoints) do
    endpoints
    |> Enum.filter(& &1.enable)
    |> Enum.flat_map(fn endpoint ->
      case EndpointManager.start(endpoint) do
        {:ok, _pid} -> []
        {:error, reason} -> [{endpoint.port, reason}]
      end
    end)
  end

  # PubSub is only started alongside the web UI, so a config replaced from a
  # console with `web: %{server: false}` has nobody to tell.
  defp notify do
    if Process.whereis(PpClient.PubSub) do
      Enum.each(@topics, fn {topic, message} ->
        Phoenix.PubSub.broadcast(PpClient.PubSub, topic, {message, nil})
      end)
    end
  end

  ## Writing

  @doc """
  The current tables rendered as the text of a `pp.exs`.

  What comes out is flat: the variables and `System.fetch_env!/1` calls a
  hand-written file used are already resolved, because what is in the tables is
  their result. It parses back into the same configuration, which is the point —
  everything else about a config file this cannot preserve is a comment.

  ## Options

    * `:redact` — replaces every credential with `:redacted`. For a copy that is
      going to be displayed rather than saved: the marker is an atom, so a file
      made out of it fails validation instead of quietly dialling with a
      placeholder for a password.
  """
  @spec dump(keyword()) :: String.t()
  def dump(opts \\ []) do
    redact? = Keyword.get(opts, :redact, false)

    """
    # pp.exs, exported from the PP Client admin UI (v#{PpClient.app_version()}).
    #
    # The format the client reads at boot: an Elixir script whose last expression
    # is a map. pp.example.exs documents what each key means.
    #
    # Every value is written out literally, credentials included, so keep this
    # file wherever you keep the pp.exs it replaces.

    %{
      web: #{dump_web()},
      endpoints: #{items(dump_endpoints())},
      servers: #{items(dump_servers(redact?))},
      dns: #{items(dump_dns())},
      profiles: #{items(dump_profiles())},
      conditions: #{dump_conditions()}
    }
    """
    |> format!()
  end

  # Generated a line at a time and then run through the formatter, which is what
  # decides the indentation and where an entry is too long for one line. It
  # doubles as a syntax check on the output: a file that will not format is a
  # file that will not parse either, and it should fail here rather than at the
  # next boot.
  defp format!(source) do
    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp items([]), do: "[]"
  defp items(entries), do: "[\n" <> Enum.join(entries, ",\n") <> "\n]"

  defp dump_web do
    case web() do
      nil -> "%{server: true}"
      web -> inspect(web, limit: :infinity)
    end
  end

  defp dump_endpoints do
    Enum.map(EndpointManager.all_endpoints(), fn endpoint ->
      "%{enable: #{endpoint.enable}, type: #{inspect(endpoint.type)}, " <>
        "ip: #{inspect(endpoint.ip)}, port: #{endpoint.port}, " <>
        "options: #{inspect(endpoint.options, limit: :infinity)}}"
    end)
  end

  defp dump_servers(redact?) do
    Enum.map(ServerManager.all_servers(), fn server ->
      opts = if redact?, do: Redact.setting(server.opts), else: server.opts

      "#{key_text(server.name)} %{enable: #{server.enable}, " <>
        "type: #{inspect(server.type)}, opts: #{dump_opts(server.type, opts)}}"
    end)
  end

  defp dump_opts("exps", opts), do: opts_text([:uri, :encrypt_type, :encrypt_key], opts)
  defp dump_opts("cf-workers", opts), do: opts_text([:uri, :password], opts)
  defp dump_opts("socks5", opts), do: opts_text([:host, :port], opts)

  # `ProxyServer.validate/1` rejects every other type, so this is only reached by
  # a server put straight into the table. Written out whole rather than dropped,
  # so whatever is there is at least visible in the export.
  defp dump_opts(_type, opts), do: opts |> Enum.to_list() |> inspect(limit: :infinity)

  defp opts_text(keys, opts) do
    keys
    |> Enum.map_join(", ", &"#{&1}: #{inspect(opts[&1], limit: :infinity)}")
    |> then(&"[#{&1}]")
  end

  defp dump_dns do
    Enum.map(DnsRecordManager.all_records(), fn record ->
      "%{enable: #{record.enable}, domain: #{inspect(record.domain)}, " <>
        "ip: #{inspect(DnsRecord.format_ip(record.ip))}}"
    end)
  end

  defp dump_profiles do
    Enum.map(ProfileManager.all_profiles(), fn profile ->
      servers = Enum.map_join(profile.servers, ", ", &atom_text/1)

      "%{name: #{inspect(profile.name)}, type: #{inspect(profile.type)}, " <>
        "enabled: #{profile.enabled}, servers: [#{servers}]}"
    end)
  end

  # A disabled condition is written out commented, which is as close as the file
  # format gets: it keeps the line around to be re-enabled by hand, and the
  # parser skips it. Re-importing therefore drops it rather than bringing it back
  # disabled.
  defp dump_conditions do
    text =
      ConditionManager.all_conditions()
      |> Enum.map_join("\n", fn condition ->
        line = "#{pattern_text(condition)} +#{condition.profile_name}"
        if condition.enabled, do: line, else: "; " <> line
      end)

    cond do
      text == "" ->
        ~s("")

      # A heredoc is what makes this section readable, but a pattern is free text
      # from the conditions page and one containing `"""` would close the heredoc
      # early. A plain string is uglier than writing a file that does not parse.
      String.contains?(text, ~s(""")) ->
        inspect(text <> "\n")

      true ->
        ~s(""") <> "\n" <> text <> "\n" <> ~s(""")
    end
  end

  defp pattern_text(condition) do
    ConditionSchema.from_condition(condition).pattern
  end

  # A name is written as a bare keyword key where it can be, and quoted where it
  # cannot — `"fly-jp": %{...}` is legal, and `to_string/1` on the key it parses
  # to gives the name back either way. Nothing here turns a name into an atom:
  # the file is text, and the atom only needs to exist once it is loaded.
  @bare_atom ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @reserved ~w(nil true false)

  defp key_text(name), do: "#{quoted_name(name)}:"
  defp atom_text(name), do: ":#{quoted_name(name)}"

  defp quoted_name(name) do
    if name not in @reserved and Regex.match?(@bare_atom, name) do
      name
    else
      inspect(name)
    end
  end

  defp brief(term), do: inspect(term, limit: 5, printable_limit: 80)
end

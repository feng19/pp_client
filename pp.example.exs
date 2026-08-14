# PP Client configuration template
#
# Usage: copy this file to pp.exs in the directory you start pp_client from,
# then adjust it. pp.exs is in .gitignore, so it never gets committed.
#
# This file is an Elixir script whose last expression must evaluate to a map.
# All of the supported top-level keys are optional:
# :web, :endpoints, :servers, :profiles and :conditions.
#
# The /admin/config page writes this format too: it downloads the running
# configuration as a pp.exs, and imports one back over it. What it writes is flat
# — no variables, no comments, and the environment lookups below already resolved
# — so a hand-written file like this one is worth keeping if you want them.

# Values can be bound up front and reused below. Keep secrets in the environment.
encrypt_key = System.get_env("EXPS_ENCRYPT_KEY") || "change-me"
password = System.get_env("PP_CF_PASSWORD") || "change-me"

%{
  # -- Web admin UI ------------------------------------------------------
  # The web UI only starts when server: true. Drop this section, or set
  # server: false, to run without it.
  # These options are passed straight to PpClientWeb.Endpoint. Note that
  # anything configured for PpClientWeb.Endpoint in config/*.exs takes
  # precedence over what is set here.
  web: %{
    server: true,
    # Loopback only. Use ip: {0, 0, 0, 0} to reach it from the local network.
    http: [ip: {127, 0, 0, 1}, port: 8081]
  },

  # -- Local listeners ---------------------------------------------------
  # type:    :socks5 | :http | :http_to_socks5 | :auto
  # ip:      defaults to {127, 0, 0, 1}; {0, 0, 0, 0} exposes it to the network
  # enable:  defaults to true; false leaves the port unbound
  # options: [profile: "name"] pins every connection to that profile, while
  #          [] routes per the conditions below and falls back to direct
  endpoints: [
    %{type: :socks5, port: 9050, options: [profile: "p"]},
    %{type: :http, port: 9060, options: []},
    # HTTP in, SOCKS5 out: the profile must hold at least one socks5 server
    %{type: :http_to_socks5, port: 1080, options: [profile: "c"]},
    %{enable: false, type: :auto, ip: {0, 0, 0, 0}, port: 9070, options: []}
  ],

  # -- Upstream proxy servers --------------------------------------------
  # The key is the atom that profiles refer to; a profile lists those keys and
  # nothing else, so one server can back several profiles and is defined once.
  # Also editable on the /admin/servers page, where edits live in memory only —
  # keep the ones that matter here, or download them from /admin/config.
  # enable defaults to true, and applies everywhere the server is referenced.
  # opts per type:
  #   "exps"       uri (ws/wss), encrypt_type (:none | :once), encrypt_key
  #   "cf-workers" uri (ws/wss), password
  #   "socks5"     host, port
  servers: [
    my_exps: %{
      type: "exps",
      opts: [uri: "wss://example.com/ws", encrypt_type: :once, encrypt_key: encrypt_key]
    },
    my_cf: %{
      type: "cf-workers",
      opts: [uri: "wss://example.workers.dev", password: password]
    },
    local_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1088]},
    backup_exps: %{
      enable: false,
      type: "exps",
      opts: [uri: "wss://backup.example.com/ws", encrypt_type: :none, encrypt_key: nil]
    }
  ],

  # -- DNS records -------------------------------------------------------
  # Hand-maintained domain -> IP overrides for the upstream servers above.
  # Before dialling a server, the client looks its hostname up here; a hit is
  # dialled by IP (the TLS SNI and the Host header still carry the domain), a
  # miss goes to the system resolver as usual. Nothing is resolved or cached
  # automatically — these are the records you enter here or on the
  # /admin/dns page, where edits live in memory only.
  # enable defaults to true; false keeps the record around but ignores it.
  dns: [
    %{domain: "example.com", ip: "104.21.1.86"},
    %{enable: false, domain: "backup.example.com", ip: "172.67.128.240"}
  ],

  # -- Profiles ----------------------------------------------------------
  # servers lists the keys from the section above — a profile refers to servers,
  # it never defines them. An unknown key fails at startup.
  # type: :remote needs at least one server. With several, one is picked at
  # random per connection, which doubles as failover.
  # type: :direct connects directly and takes servers: [].
  # enabled defaults to true.
  profiles: [
    %{name: "p", type: :remote, servers: [:my_exps, :my_cf, :backup_exps]},
    %{name: "c", type: :remote, servers: [:local_socks]},
    %{name: "d", type: :direct, servers: []}
  ],

  # -- Routing conditions ------------------------------------------------
  # SwitchyOmega condition format: `host-wildcard +profile-name`, one space
  # in between. Conditions are matched top-down and the first hit wins; a
  # request matching none of them goes direct.
  # `*` matches any number of characters, `?` matches exactly one.
  # Lines starting with ; ! [ @note or @with are ignored, so they can be
  # used for comments.
  conditions: """
  *.google.com +p
  *.googleapis.com +p
  *.gstatic.com +p
  github.com +p
  *.github.com +p
  *.openai.com +c
  *.anthropic.com +c
  ; keep the intranet off the proxy
  *.internal.example.org +d
  ; catch-all: uncomment to send everything else through p
  ; * +p
  """
}

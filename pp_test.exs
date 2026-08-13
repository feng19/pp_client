# Runtime configuration for the test environment, loaded by PpClient.Application.
#
# Only the web section is set here. server: true is what puts PpClientWeb.Endpoint
# into the supervision tree, which the LiveView tests need in order to render.
# No listener is actually bound: config/test.exs sets server: false on the
# endpoint itself, and endpoint config from config/*.exs wins over these options.
#
# Endpoints, servers, profiles and conditions are deliberately left out. The tests
# set up whatever they need themselves and wipe the ETS tables between runs, and
# declaring endpoints here would bind real ports while the suite runs.
%{
  web: %{server: true}
}

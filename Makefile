.PHONY: run stop find_process build uninstall release

run:
	iex -S mix

stop:
	@elixir --name pp_client_killer@127.0.0.1 --eval ":rpc.call(:'pp_client@127.0.0.1', PpClient, :stop, [])"

find_process:
	ps -ef | grep pp_client

build:
	MIX_ENV=prod mix escript.build

uninstall:
	pp_client maintenance uninstall -f

release:
	BURRITO_TARGET=macos_aarch64 MIX_ENV=prod mix release --force --overwrite
.PHONY: run stop find_process build

run:
	iex -S mix

stop:
	@elixir --name pp_client_killer@127.0.0.1 --eval ":rpc.call(:'pp_client@127.0.0.1', PpClient, :stop, [])"

find_process:
	ps -ef | grep pp_client

build:
	mix escript.build

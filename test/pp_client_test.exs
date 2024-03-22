defmodule PpClientTest do
  use ExUnit.Case
  doctest PpClient

  test "greets the world" do
    assert PpClient.hello() == :world
  end
end

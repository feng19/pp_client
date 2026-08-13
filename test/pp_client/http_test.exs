defmodule PpClient.HttpTest do
  use ExUnit.Case, async: true

  alias PpClient.Http

  @domain 0x03

  describe "parse_request/1 CONNECT" do
    test "host and port" do
      assert Http.parse_request("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n") ==
               {:ok, {@domain, "example.com", 443}, nil}
    end

    test "host without a port defaults to 80" do
      assert Http.parse_request("CONNECT example.com HTTP/1.1\r\n\r\n") ==
               {:ok, {@domain, "example.com", 80}, nil}
    end

    test "ipv4 literal" do
      assert Http.parse_request("CONNECT 10.0.0.7:8080 HTTP/1.1\r\n\r\n") ==
               {:ok, {@domain, "10.0.0.7", 8080}, nil}
    end

    test "ipv6 literal" do
      assert Http.parse_request("CONNECT [::1]:8080 HTTP/1.1\r\n\r\n") ==
               {:ok, {@domain, "::1", 8080}, nil}
    end

    test "a malformed line is refused instead of raising" do
      # No space after the method, so this lands in the general clause.
      assert Http.parse_request("CONNECT\r\n\r\n") == {:error, :error_request_line}
      # An empty target, which does reach the CONNECT clause.
      assert Http.parse_request("CONNECT \r\n\r\n") == {:error, :error_request_line}
    end

    test "an incomplete line asks for more" do
      assert Http.parse_request("CONNECT example.com:443 HTTP/1.1") == {:error, :need_more}
    end
  end

  describe "parse_request/1 absolute form" do
    test "rewrites to origin form with the method separated from the target" do
      request = "GET http://example.com/index.html HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, {@domain, "example.com", 80}, next} = Http.parse_request(request)
      assert next == "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n"
    end

    test "does not leave a stray CR in the request line" do
      request = "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, _target, next} = Http.parse_request(request)
      refute next =~ "\r\r"
      assert [request_line | _] = String.split(next, "\r\n")
      assert request_line == "GET / HTTP/1.1"
    end

    test "an authority only URI becomes a root path" do
      request = "GET http://example.com HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, {@domain, "example.com", 80}, next} = Http.parse_request(request)
      assert next == "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    end

    test "keeps the query string" do
      request = "GET http://example.com/search?q=elixir&p=2 HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, {@domain, "example.com", 80}, next} = Http.parse_request(request)
      assert next == "GET /search?q=elixir&p=2 HTTP/1.1\r\nHost: example.com\r\n\r\n"
    end

    test "keeps an empty query string marker" do
      request = "GET http://example.com/search? HTTP/1.1\r\n\r\n"

      assert {:ok, _target, next} = Http.parse_request(request)
      assert next == "GET /search? HTTP/1.1\r\n\r\n"
    end

    test "carries a non default port through" do
      request = "GET http://example.com:8080/x HTTP/1.1\r\nHost: example.com:8080\r\n\r\n"

      assert {:ok, {@domain, "example.com", 8080}, next} = Http.parse_request(request)
      assert next == "GET /x HTTP/1.1\r\nHost: example.com:8080\r\n\r\n"
    end

    test "preserves headers and body after the request line" do
      body = "name=value"

      request =
        "POST http://example.com/submit HTTP/1.1\r\nHost: example.com\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"

      assert {:ok, {@domain, "example.com", 80}, next} = Http.parse_request(request)

      assert next ==
               "POST /submit HTTP/1.1\r\nHost: example.com\r\n" <>
                 "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"
    end

    test "handles LF only line endings" do
      request = "GET http://example.com/x HTTP/1.1\nHost: example.com\n\n"

      assert {:ok, {@domain, "example.com", 80}, next} = Http.parse_request(request)
      assert next == "GET /x HTTP/1.1\r\nHost: example.com\n\n"
    end

    test "a two token request line is refused instead of raising" do
      assert Http.parse_request("GET /index.html\r\n\r\n") == {:error, :error_request_line}
    end

    test "an incomplete request asks for more" do
      assert Http.parse_request("GET http://example.com/ HTTP/1.1") == {:error, :need_more}
    end
  end
end

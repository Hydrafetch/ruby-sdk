require "json"
require "socket"
require "uri"

class StubServer
  Request = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true)

  attr_reader :port, :requests

  def initialize(&handler)
    @handler = handler
    @requests = []
    @mutex = Mutex.new
    @socket = TCPServer.new("127.0.0.1", 0)
    @port = @socket.addr[1]
    @running = true
    @thread = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def stop
    @running = false
    @socket.close rescue nil
    @thread.kill
    @thread.join(1)
  end

  private

  def accept_loop
    while @running
      client = begin
        @socket.accept
      rescue IOError, Errno::EBADF
        break
      end
      handle(client)
    end
  end

  def handle(client)
    line = client.gets
    return client.close if line.nil?

    method, target, = line.split(" ")
    headers = {}
    while (header = client.gets) && header.strip != ""
      key, value = header.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end

    body = nil
    length = headers["content-length"].to_i
    body = client.read(length) if length.positive?

    uri = URI.parse(target)
    query = uri.query ? URI.decode_www_form(uri.query).to_h : {}
    parsed = begin
      body && !body.empty? ? JSON.parse(body) : nil
    rescue JSON::ParserError
      nil
    end

    request = Request.new(method: method, path: uri.path, query: query, headers: headers, body: parsed)
    @mutex.synchronize { @requests << request }

    status, payload = @handler.call(request)
    write(client, status, payload)
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    client.close rescue nil
  end

  def write(client, status, payload)
    client.print("HTTP/1.1 #{status} X\r\n")
    client.print("Content-Type: application/json\r\n")
    client.print("Content-Length: #{payload.bytesize}\r\n")
    client.print("Connection: close\r\n\r\n")
    client.print(payload)
  end
end

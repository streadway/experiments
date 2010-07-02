## Copyright (c) Sean Treaday <sean@soundcloud.com>
## Permission granted to use and redistribute as long as the above copyright and this permission
## are included in redistributions.
#
# Hypothesis: Fronting single request (Rails) app server backends with nginx -> haproxy -> backend
# will offer the best possible throughput in the face of slow clients.
#
# This simulates the 1 request per process model of a standard Rails install and infers that the
# buffering nginx provides releases the backend as quickly as possible to accept new requests.
#
# Direct to backend
# HAProxy -> backend
# HAProxy -> nginx -> backend
# nginx -> backend
# nginx -> haproxy -> backend
#
# Client - throttled download to read at 100 kbytes per second
# Server - immediately write 1MB HTTP response after accepting client, only serve one connection at a time
# HAproxy - maxconn 1 for both direct backend and nginx backend
# nginx - buffered proxy_pass to direct backend and haproxy backend
#
# Experiment: Measure the time it takes until the request queue is empty according to the
# server through the different pipelines
#
# Each experiement will execute differet pipelines with the following workload:
# 6 parallel reads with 5 slow clients and 1 fast client to backend that delivers a 1 MB response
#
# Measure the time of the latest server close and compare the difference between the last
# server close and last client read.
#
# This last server close is when the backend pool is no longer blocked on IO and can be used
# for further requests.
#
# Results (filtered and formatted slightly, times in milliseconds)
#
# CLIENT RUNTIME:    10822 nginx to haproxy to backend
# SERVER RUNTIME:      432 (duration according to server)
#
# CLIENT RUNTIME:    10775 nginx to backend
# SERVER RUNTIME:      336 (duration according to server)
#
# CLIENT RUNTIME:    65354 haproxy to nginx to backend
# SERVER RUNTIME:    64205 (duration according to server)
#
# CLIENT RUNTIME:    63911 haproxy to backend
# SERVER RUNTIME:    53564 (duration according to server)
#
# CLIENT RUNTIME:    33527 direct to backend
# SERVER RUNTIME:    28233 (duration according to server)
#
# Caveats:
#
# The listen depth of the server accept socket was 10, which should cover all the connections from either nginx or direct
# In a real world scenario, the number of requests dispatched should not be queued on the listen backlog of the server
# because this would increase time to first byte.
#
require 'socket'
require 'thread'
require 'tmpdir'

BACKEND_PORT=14000
HAPROXY_BACKEND_PORT=14010
HAPROXY_NGINX_PORT=14011
NGINX_BACKEND_PORT=14020
NGINX_HAPROXY_PORT=14021

$mutex = Mutex.new
def log(str); $mutex.synchronize { STDERR.puts(str); STDERR.flush }; end

nginx_path, nginx_config  = `which nginx`.strip, Dir.tmpdir + '/slow-test-nginx.conf'
nginx_cmd = "#{nginx_path} -c #{nginx_config}"
log("Can't find nginx in your path") && exit(1) unless $?.success?

File.open(nginx_config, 'w') do |config| config.write <<-HERE
daemon off;

events {
  worker_connections  1000;
}

http {
  server {
    server_name   direct;
    listen        #{NGINX_BACKEND_PORT};
		location / {
			proxy_pass http://127.0.0.1:14000;
		}
  }

  server {
    server_name   haproxy;
    listen        #{NGINX_HAPROXY_PORT};
		location / {
			proxy_pass http://127.0.0.1:14010;
		}
  }
}
HERE
end


haproxy_path, haproxy_config = `which haproxy`.strip, Dir.tmpdir + '/slow-test-haproxy.conf'
haproxy_cmd = "#{haproxy_path} -q -db -f #{haproxy_config}"
log("Can't find haproxy in your path") && exit(1) unless $?.success?

File.open(haproxy_config, 'w') do |config| config.write <<-HERE
defaults
  mode        http

listen direct 0.0.0.0:#{HAPROXY_BACKEND_PORT}
  server  backend 127.0.0.1:#{BACKEND_PORT} maxconn 1

listen nginx 0.0.0.0:#{HAPROXY_NGINX_PORT}
  server  backend 127.0.0.1:#{NGINX_BACKEND_PORT} maxconn 1
HERE
end

log "Using:"
log "  nginx: #{nginx_cmd}"
log "  haproxy: #{haproxy_cmd}"
log ""
log "Press CTRL-C to quit"

trap("INT") { $pids.each { |pid| Process.kill("KILL", pid) }; $threads.each { |thread| thread.kill } }

$pids = []
$pids << fork { exec nginx_cmd }
$pids << fork { exec haproxy_cmd }

# 1MB server
$threads = []
$threads << Thread.new do
  min_start = max_end = nil

  server = TCPServer.open(0, BACKEND_PORT)
  server.listen(10)
  while client = server.accept
    begin
      client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)
      id = [ client.addr[1], client.peeraddr[1] ].join('->')
      log "SERVER ACCEPTED: #{Time.now} #{id}"

      client.write([
        "HTTP/1.1 200 OK",
        "Content-Length: #{1024 * 1024}", # 1MB of X
        "",
        "X" * 1024 * 1024
      ].join("\r\n"))
      log "SERVER WRITTEN: #{Time.now} #{id}"
    rescue
      log "SERVER EXCEPTION: #{Time.now} #{id}"
    ensure
      client.close
      log "SERVER CLOSED: #{Time.now} #{id}"

      # Perform measurement
      $max_server_close = [ $max_server_close, Time.now ].max if $max_server_close
    end
  end
end

def request(port, bytes_per_second=1024*1024)
  Thread.new do
    buffer_size = 1024
    sock = TCPSocket.open(0, port)
    id = [ sock.addr[1], sock.peeraddr[1], bytes_per_second ].join('->')
    log "CLIENT CONNECTED: #{Time.now} #{id}"

    sock.write("GET / HTTP/1.0\r\n\r\n")
    sock.flush
    log "CLIENT REQUESTED: #{Time.now} #{id}"

    headers, data = sock.read(buffer_size).split("\r\n\r\n")
    log "CLIENT FIRST BYTE: #{Time.now} #{id}"

    remaining = (1024 * 1024) - data.size # 1MB of body
    until remaining <= 0
      sleep buffer_size.to_f / bytes_per_second.to_f
      if buf = sock.read(buffer_size)
        remaining -= buf.size
      else
        remaining = 0
      end
    end

    log "CLIENT FINISH: #{Time.now} #{id}"
    sock.close
  end
end

def experiment(description)
  $max_server_close = Time.now

  log("START: #{description}")
  t1 = Time.now
  begin
    return yield
  ensure
    t2 = Time.now
    log("SERVER RUNTIME: %8d (duration according to server)" % [($max_server_close - t1) * 1000, description])
    log("CLIENT RUNTIME: %8d %s" % [(t2-t1) * 1000, description])
  end
end

sleep(2)

[
  [ BACKEND_PORT, "direct to backend" ],
  [ HAPROXY_BACKEND_PORT, "haproxy to backend" ],
  [ HAPROXY_NGINX_PORT, "haproxy to nginx to backend" ],
  [ NGINX_BACKEND_PORT, "nginx to backend" ],
  [ NGINX_HAPROXY_PORT, "nginx to haproxy to backend" ],
].reverse.each do |port, desc|
  experiment("parallel #{desc}") do
    threads = (0..5).map { request(port, 100*1024) }
    threads << request(port, 1024*1024)

    # Launch and wait for all requests at the same time
    threads.each { |t| t.join }
  end
end

Process.waitall
$threads.each { |t| t.join }

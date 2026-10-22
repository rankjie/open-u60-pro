#!/bin/sh
# End-to-end check of RelayTunnel.swift against the Rust QUIC gateway (relay-tunnel/).
set -eu
openu60_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
openu60_work=$(mktemp -d "${TMPDIR:-/tmp}/openu60-relay-tunnel-tests.XXXXXX")
openu60_gateway_pid=
openu60_upstream_pid=
openu60_cleanup() {
    [ -n "$openu60_gateway_pid" ] && kill "$openu60_gateway_pid" 2>/dev/null || true
    [ -n "$openu60_upstream_pid" ] && kill "$openu60_upstream_pid" 2>/dev/null || true
    # The test restarts the gateway itself; this catches it if the test crashed.
    pkill -f "$openu60_work/identity" 2>/dev/null || true
    rm -rf "$openu60_work"
}
trap openu60_cleanup EXIT HUP INT TERM

openu60_wait_for() {
    openu60_tries=0
    until grep -q "$2" "$1" 2>/dev/null; do
        openu60_tries=$((openu60_tries + 1))
        if [ "$openu60_tries" -gt 100 ]; then
            echo "Timed out waiting for $1:" >&2; cat "$1" >&2; exit 1
        fi
        sleep 0.1
    done
}

(cd "$openu60_root" && cargo build -q -p relay-tunnel --bin relay-tunnel-gateway)
openu60_gateway="${CARGO_TARGET_DIR:-$openu60_root/target}/debug/relay-tunnel-gateway"

swiftc -swift-version 5 \
    "$openu60_root/mobile/ios/OpenU60/Core/Networking/RelayTunnel.swift" \
    "$openu60_root/mobile/ios/Tests/RelayTunnelTests.swift" -o "$openu60_work/tests"

# Reads one request to EOF and answers "echo:" + request. A request starting with "GET " is
# served as HTTP/1.1 keep-alive instead, so bytes must flow before any half-close.
cat > "$openu60_work/upstream.py" <<'EOF'
import socket, threading

def handle(c):
    with c:
        data = c.recv(65536)
        if data.startswith(b"GET "):
            while True:
                while b"\r\n\r\n" not in data:
                    more = c.recv(65536)
                    if not more:
                        return
                    data += more
                head, data = data.split(b"\r\n\r\n", 1)
                body = b"path:" + head.split(b" ")[1]
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        while True:
            more = c.recv(65536)
            if not more:
                break
            data += more
        c.sendall(b"echo:" + data)

server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(128)
print("upstream", server.getsockname()[1], flush=True)
while True:
    connection, _ = server.accept()
    print("accepted", flush=True)
    threading.Thread(target=handle, args=(connection,), daemon=True).start()
EOF
python3 -I -u "$openu60_work/upstream.py" > "$openu60_work/upstream.out" 2>&1 &
openu60_upstream_pid=$!
openu60_wait_for "$openu60_work/upstream.out" "^upstream "
openu60_upstream_port=$(sed -n 's/^upstream \([0-9]*\)$/\1/p' "$openu60_work/upstream.out")

# The gateway cannot report a UDP port it chose itself, so pick a free one first.
openu60_gateway_port=$(python3 -I -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# Started from a subshell so the test's SIGKILL of it is not reported as a job of this shell.
( "$openu60_gateway" "$openu60_work/identity" "127.0.0.1:$openu60_gateway_port" "127.0.0.1:$openu60_upstream_port" \
    > "$openu60_work/gateway.out" 2>&1 & echo $! > "$openu60_work/gateway.pid" )
openu60_gateway_pid=$(cat "$openu60_work/gateway.pid")
openu60_wait_for "$openu60_work/gateway.out" " pin "
openu60_pin=$(sed -n 's/^.* pin \([A-Za-z0-9_-]*\)$/\1/p' "$openu60_work/gateway.out")

"$openu60_work/tests" 127.0.0.1 "$openu60_gateway_port" "$openu60_pin" "$openu60_gateway_pid" \
    "$openu60_gateway" "$openu60_work/identity" "$openu60_upstream_port" "$openu60_work/upstream.out"

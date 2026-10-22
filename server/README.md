# OpenU60 calling server

Bun 1.3.14 runs the HTTPS-origin signaling service (behind Nginx or a Cloudflare
Tunnel). SQLite owns endpoint pairing, call sessions, command idempotency, and
the incoming-call push outbox. Media remains WebRTC between router and phone;
Coturn relays DTLS-SRTP when a direct connection cannot be established.

The same service also introduces authenticated management peers. An upgraded
router advertises support, and paired phones exchange scoped SDP/ICE through
the existing socket. Direct management uses a reliable WebRTC data channel;
failed punching falls back to the existing agent relay. Coturn's UDP listener
also supplies STUN discovery; no new listener, credential, or provisioning step
is required. See [the management protocol](../docs/remote-calling.md#automatic-management-paths)
for leases, revocation, bounds, and operation idempotency.

## Checks

```sh
bun install --frozen-lockfile
bun test
bun run typecheck
```

Tests create private temporary databases, synthetic credentials, and synthetic
APNs keys. They do not read production credential files or send Apple pushes.

## Deployment on nl1

The dedicated service uses `https://nl1.gmdns.net/openu60`, loopback TCP 46170,
TURN UDP/TCP 3478, and UDP relay ports 49160–49200. Allow the TURN ports through
the host and cloud firewalls. HTTP/WSS signaling can use a Cloudflare Tunnel;
public UDP relay traffic needs its own reachable route.

Copy `server/` into `/opt/openu60/current/server`. On a new deployment, generate
configuration with the server's public and internal relay addresses:

```sh
bun /opt/openu60/current/server/src/provision.ts /etc/openu60-calling \
  https://nl1.gmdns.net/openu60 141.144.206.203 10.0.0.221 \
  /etc/openu60-calling/apns.p8 798ULL7Y26 AHMW8A73A6 com.beexio.openu60
```

Install the existing topic-scoped APNs key at the configured path through the
operator's credential provisioning client, owned by UID 65532 and mode 0600.
Then create the state directory and start the containers:

```sh
mkdir -p /var/lib/openu60-calling
chown 65532:65532 /var/lib/openu60-calling
chmod 700 /var/lib/openu60-calling
docker-compose -f /opt/openu60/current/server/deploy/compose.yaml -p openu60-calling up -d --build
```

The provisioner requires a new configuration directory and publishes its private
files together with an atomic rename. It refuses to replace an existing directory.
The containers run as UID 65532 with no capabilities, private configuration
mounts, and a read-only application filesystem. The signaling port binds only
to loopback. Install `deploy/nginx-http.conf` to complete an HTTP-01 certificate
challenge, then install the obtained certificate under `/etc/openu60-tls/` and
enable `deploy/nginx.conf`. Test Nginx configuration before a graceful reload.

APNs is optional at process startup, but required for background incoming calls.
The optional final four provisioner arguments set the APNs path and identifiers.
For another deployment, add an `apns` object to the private JSON with `teamId`, `keyId`, `bundleId`, and
`keyFile`. The key must authorize the containing app's `.voip` topic. Keep the key
and JSON regular, mode 0600/0400, and owned by UID 65532. Each phone registers its
own Sandbox/Production environment; it must match that installed app's signing.
The health endpoint reports whether APNs and TURN are configured, without
returning credentials or endpoint details.

Create a single-use router invitation without printing it:

```sh
docker exec openu60-calling bun src/admin.ts \
  /etc/openu60-calling/calling-server.private.json invite \
  /var/lib/openu60-calling/invitation.private
```

The invitation expires after ten minutes. Transfer it through an authenticated
operator channel to the iPhone's router setup, or let an authorized provisioning
client consume it directly. Do not include it in a shell argument, log, issue,
or repository. The router persists its own generated device token before using
the invitation; identical registration retries recover the same endpoint.

In the iPhone app, open Calls and tap its connection indicator while connected to the router
for the initial enrollment. The app then pairs itself through the router's
short-lived pairing code. After that, mobile data or any Wi-Fi is sufficient.
Pairing another phone preserves the existing phones; pairing during a call is refused.
All paired phones ring for an incoming call. The first answer owns the call; other
phones stop ringing. Each phone receives its own complete SMS notification and
retains independent push-token and retry state.

## QUIC doors

A door is a regional entry to this same service: a `relay-tunnel-gateway` that accepts
QUIC on a UDP port and forwards each stream, byte for byte, to the service's loopback
HTTP port, or to another door. Clients still speak the unchanged HTTP/WebSocket protocol,
through a local forwarder; identity, pairing, calls and pushes are the service's, so a door
holds no state. Doors serve where public HTTP/HTTPS is unwanted (mainland hosting without
an ICP filing): there is no HTTP on the wire, no domain, and no public certificate.

A gateway creates its certificate once and prints its SHA-256 pin. The pin travels in the
door address, `quic://host:port#pin`, and is the only trust anchor; TLS 1.3 handshake
signatures are still verified. ALPN is `openu60-tunnel/1`. Pick an otherwise unused high UDP
port; avoid 443/udp (HTTP/3) and well-known VPN ports (500/4500, 1194, 51820), which some
networks inspect or throttle.

Build the static binary for the host's architecture and install the unit:

```sh
cargo zigbuild --release -p relay-tunnel --bin relay-tunnel-gateway --target x86_64-unknown-linux-musl
install -m 755 relay-tunnel-gateway /opt/openu60/door/
install -m 644 server/deploy/openu60-door.service /etc/systemd/system/
systemctl edit openu60-door   # Environment=OPENU60_DOOR_UPSTREAM=…
systemctl enable --now openu60-door && journalctl -u openu60-door -n 1   # prints the pin
```

On the service host the upstream is `127.0.0.1:46170`. A distant door chains to a door on
the service host, `OPENU60_DOOR_UPSTREAM=quic://<service-host>:47853#<pin>`, so the long
haul is QUIC as well. Allow the UDP port in the host and cloud firewalls.

Advertise doors by adding them to the private configuration and restarting the service:

```json
"doors": [{ "address": "quic://203.0.113.5:47853#<pin>", "label": "Hangzhou" }]
```

At most eight doors are accepted; the list is sent in `hello` and `/v1/status`. Routers and
phones keep the last list, probe the HTTPS address and each door end to end before
connecting, and use the fastest that answers; the phone also offers a manual choice.

## Protocol and failure behavior

For an enrolled router, phones can now connect using the device string shown by
the touchscreen's **Wi-Fi → Connect app** page and the router password. Device
discovery publishes only the router identity and its registered P-256 public key.
The password is HPKE-encrypted to the router and verified there before the server
creates an independent phone endpoint. The phone retains its pending credential
before requesting approval, allowing a lost response to be recovered without
adding another endpoint. Existing pairings and the advanced setup remain valid.

- Paired phones may relay bounded JSON management requests through the router's
  authenticated socket. A device journal protects writes across LAN/relay
  switching. Authentication, enrollment, Live Activity configuration and raw LAN
  throughput endpoints stay local. WebSocket credentials use the Authorization
  header, never URL query parameters.
- Calls and commands have stable UUIDs. A command is persisted before delivery;
  the device writes its execution journal before touching the modem. A repeated
  command replays its result or reports an unknown outcome, never redials.
- One active call per router is enforced transactionally. Modem events carry a
  monotonic sequence within that call; stale events cannot resurrect an ended
  call. SDP and ICE credentials are forwarded in memory, not stored in SQLite.
- The router is the WebRTC offerer. The phone requests a fresh media session
  when waking or reconnecting without an existing peer connection.
- A real incoming call creates a durable push-outbox item. Transport and
  temporary APNs failures retry only while the call is still ringing. Invalid
  device tokens are disabled. A CallKit UUID deduplicates retry delivery.
- Provider rejection, modem errors, media timeouts, expired commands, revoked
  pairing, and unsupported modem state are explicit outcomes.
- SMS notifications use the ordinary app APNs topic, separate from `.voip`.
  Pending outboxes contain the full sender/text for retry; terminal outcomes clear
  that payload. Oversized messages split below Apple's 4,096-byte limit, preserving
  Unicode and all text. Revoked pairings and invalid tokens stop delivery.
  See [Apple's notification request contract](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
- HTTP payloads, SDP, ICE candidates, push payloads, and credentials are not
  application log fields. The private database contains call metadata and push
  tokens; back it up and restrict access as a credential-bearing service store.

## Live network check

`src/live-probe.ts` consumes a private invitation file, creates synthetic endpoints,
exercises public HTTPS/WSS, and revokes the synthetic enrollment afterward. It
registers no push token and sends no modem command to a real router. Its private
output contains short-lived TURN credentials for the explicit relay test:

```sh
bun server/src/live-probe.ts https://nl1.gmdns.net/openu60 \
  target/probe-invitation.private target/relay-test.private.json
OPENU60_TURN_TEST_FILE="$PWD/target/relay-test.private.json" \
  cargo test -p zte-agent external_turn_ -- --ignored --test-threads=1
```

The relay test forces both peers to use TURN and checks different synthetic G.711
payloads in both directions. Never print the credential file. Its output path
must be new, mode 0600, and owned by the test process. The generated credentials
expire in one hour. Real iPhone VoIP push delivery requires its registered token
and a device test; `/health` only reports provider configuration.

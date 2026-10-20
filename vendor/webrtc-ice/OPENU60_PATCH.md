# OpenU60 TURN TCP patch

Source: crates.io `webrtc-ice` 0.17.2, upstream webrtc-rs commit `1da3fe8ee84db8d266322cbcfcb357c745959a8e`.
Registry package checksum: `5b7fd30f52e6fda8664779b84b7904b2553b76fee24d9ca665e774ae32b13f53`.
Upstream MIT and Apache-2.0 licenses are retained. The workspace patches only this
crate; the WebRTC API remains pinned to 0.17.1 in the application lockfile.

Changes are confined to `src/agent/mod.rs`, `src/agent/agent_gather.rs`, and the
added `src/agent/turn_tcp.rs`. TURN TCP URLs open a bounded TCP connection and
adapt its framed messages to the existing `Conn` packet interface. Relay
allocations continue to request UDP transport to the remote peer. This adds
TURN over TCP, not ICE-TCP or TURN over TLS.

Framing follows [RFC 8656 sections 12.4–12.6](https://www.rfc-editor.org/rfc/rfc8656.html#section-12.4).
It preserves partially received packets across cancellation, handles coalesced
STUN and ChannelData messages, and strips/adds TCP ChannelData alignment padding.
Cancelled or failed writes close the logical transport so a partial frame cannot
be reused. Close unblocks readers and writers. DNS, connect, write, and shutdown
attempts have finite deadlines. Credentials and packet contents are not logged.

Focused checks:

```sh
CARGO_TARGET_DIR="$PWD/target" cargo test \
  --manifest-path vendor/webrtc-ice/Cargo.toml --lib agent::turn_tcp::tests
OPENU60_TURN_TEST_FILE="$PWD/target/relay-final.private.json" \
  cargo test -p zte-agent external_turn_ -- --ignored --test-threads=1
```

The first command uses synthetic TCP peers. The second explicitly consumes a
private credential file produced by the server's live probe and verifies real
DTLS-SRTP audio in both directions over UDP-only and TCP-only TURN paths. It
requires a reachable server and is excluded from ordinary offline unit runs.

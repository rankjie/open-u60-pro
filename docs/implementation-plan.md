# Implementation plan

## Completion criteria

- On L17, a real Apple VoIP push wakes the complete application from the
  background with signaling deliberately disconnected; CallKit answers, activates
  audio, exchanges RTP in both directions, supports mute/output routing, and ends
  cleanly. The test view always returns to the complete application.
- One device connection layer prefers a verified local agent, falls back to the
  authenticated server relay off-LAN, and exposes actionable connection failures.
  A write whose delivery is uncertain is never blindly replayed on another path.
- The paired phone remotely reads and sends SMS; device events trigger ordinary
  APNs message notifications. PushKit remains limited to incoming calls.
- Navigation uses Home, Calls, Messages, Settings. Calls has its own tab; device,
  automation, diagnostics and advanced controls live in meaningful Settings
  groups with native back navigation and existing features preserved. A compact
  USB charging toggle appears at the top of Home only while USB is connected;
  cable attachment never presents a modal.
- Targeted regression checks, signed builds, authorized deployment and device
  verification pass; known P0/P1 findings are fixed or explicitly unresolved.

## Current work

1. Verified: real APNs/PushKit background receipt and bidirectional native media
   (3,899 PCMU packets sent and 3,007 received at the synthetic router), mute and
   clean CallKit audio deactivation, speaker and receiver routing. A reconnect
   snapshot's duplicate media requests were reproduced and fixed. Intermittent
   post-connect direct ICE failure now recovers through one TURN-only negotiation
   for the same call, preserving CallKit and mute. A real background call moved
   onto `relay/udp` without a CallKit end; the Simulator regression also passed.
   Verification uses a synthetic
   router on the existing public service. Synthetic credentials are isolated
   private USB-transfer inputs; the real pairing Keychain remains untouched.
2. Implemented and deployed: authenticated server JSON relay,
   the shared device execution journal and iOS LAN-first transport. A six-request
   client limit shares capacity with call control. Discovery checks the enrolled
   router identity before local reauthentication; a lost write response retains
   its UUID on relay fallback. Call control admits one operation centrally, then
   attempts the existing device worker over LAN before relay. The server and
   device retain the original operation ID and expiry. U60's incorrect 2025 clock
   was corrected from the trusted Mac clock for TLS bootstrap. The authenticated
   hello supplies a monotonic server-time anchor, also
   exposed as `agentTime` for local request expiry. Journal history uses admission
   order so a clock correction cannot forget a completed effect.
3. Implemented, deployed and physically verified on L16: remote SMS
   uses the management transport. A firmware event subscription plus bounded
   database reconciliation identifies new received SMS, seeds historical messages
   without notifying, and persists pending events before sending. Notifications
   carry the sender and complete message, including codes, as requested. Long
   messages split into stable parts below APNs's 4,096-byte payload limit. The App
   registers its ordinary APNs token separately from PushKit and opens Messages
   on a notification tap. Settings includes a durable synthetic SMS test that
   follows the same device/server outbox and ordinary APNs path without changing
   the SMS database. Real ordinary APNs delivered the complete synthetic text
   while the App was backgrounded; tapping a notification selected Messages in
   the complete App. Actual carrier receive/send awaits the SIM.
4. Installed and observed: four tabs, grouped Settings, and a compact Home USB
   charging switch. Turning it on detached router USB/ADB; turning it off restored
   ADB within nine seconds using the App switch, with the same
   cable connected. Hardware readback showed powerbank=0 and Type-C sink role.
   A longer source-mode test reproduced the firmware clearing its CC flag and
   stale charger status hiding the control. The agent now reads the powerbank
   controller directly; an active source retains its off switch. The final Home
   switch stayed visible across multiple polls while enabled, then disabling it
   restored USB/ADB without unplugging. Controller readback was 0 and the port
   returned to sink. Normal complete App and the updated agent are installed.

## Current deployment and acceptance boundary

The server runs the management/SMS implementation on nl1 and the updated agent
is installed on the real U60. On 2026-10-21 the user selected L16, an iPhone 16 Pro
running iOS 26.4.2, for the remaining acceptance. Its complete App uses the Beexio
team and the dedicated App ID's development push profile, managed by Xcode.

The real U60 was enrolled and L16 paired through the normal Calls screen using a
private transferred invitation. The App showed the service connected and the
router online. The imported invitation was consumed through the normal client;
no test shell or automatic operator launch hook is installed.

The phone moved from `ZZZZTE_5G` to its original `L_5G` network, where Home
automatically displayed "Via server" and fresh router data. Returning to ZTE
Wi-Fi restored "Connected" and fresh data without editing the gateway or
re-pairing. A test-notification write also succeeded over the server relay.

For the background SMS check, one synthetic event was durably queued on the
offline router. After the App was backgrounded and the phone returned to its
internet-connected Wi-Fi, the router's test uplink was restored. A real Apple
notification arrived with the sender and all English, Chinese, emoji and test
code text. A separate notification tap opened Messages with the SMS tab selected.
The synthetic message is not inserted into the real SMS database.

The no-SIM router borrowed an encrypted route through the Mac for these checks;
TLS validation remained enabled. The temporary hosts entry, port rules, TCP
forwarder, ADB forwarding and SSH tunnel were removed. Pairing remains installed.
L16 returned to its original Wi-Fi and its original two-minute auto-lock setting;
the owned automation service was stopped. Independent remote operation still
requires the U60 to have its own working uplink.

Physical SIM calling, carrier registration, vendor PCM ABI/direction and audible
cellular speech are deferred until the SIM arrives. Synthetic evidence does not
satisfy those checks. APNs acceptance alone does not establish device delivery.

## Management and SMS transport contract

The paired phone uses authenticated HTTPS to relay bounded agent JSON requests
over the router's existing outbound WSS connection. The phone first probes the
configured local agent and verifies its enrolled router identity. Successful
local access is preferred; an unavailable local route falls back to the relay.
Pairing grants remote administration for that one router, with revocation checked
at request admission and response delivery. The server is a trusted relay; TLS
protects both hops and management bodies are never logged or persisted there.

Writes carry one request UUID across both routes. A device-owned durable journal
claims the UUID and request fingerprint before execution. A duplicate or interrupted
write reports its prior/unknown delivery state rather than repeating its effect.
Reads can fall back automatically; uncertain writes must reconcile rather than
silently replay. Request bodies, response sizes, concurrency and waits are bounded.
Raw LAN throughput tests stay local because a relay would measure another link.

The iOS transport probes router identity/time, uses the local
`/api/management` endpoint when reachable and send the same effect UUID through
`/v1/agent` on fallback. Expiry is expressed in the selected transport's time
domain with the original remaining deadline; only method/path/body define the
device effect fingerprint. The last 1,024 outcomes are retained by admission
order; unfinished effects are never evicted to make them executable again.

Call control retains server admission and the existing single call journal:
admit a stable call-operation UUID centrally, deliver its canonical command over
the verified local path first, then relay the same command/expiry if needed.
Local delivery only acknowledges queue admission; the existing server result
still completes the CallKit action. It must not create a second dial or a separate
modem execution path. Offline cellular-call acceptance remains outside this work.

New-message notifications use ordinary APNs with the full sender and message,
including verification codes. Device and server outboxes retain content while
delivery is pending; a server acceptance removes the device copy, and an Apple
acceptance, rejection, expiry or revocation clears the server payload. A pending
notification expires after one day or twelve provider attempts. Stable event and
part identifiers deduplicate retries; no exactly-once Apple delivery is claimed.
SMS sends use device write deduplication. PushKit is reserved for incoming calls.

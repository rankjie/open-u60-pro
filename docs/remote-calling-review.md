# Remote calling review

Reviewed on 2026-10-20–21: server authorization, command persistence and expiry;
router command ownership, cancellation and AT submission; iOS call ownership,
WebRTC negotiation, signaling recovery, CallKit actions and audio activation;
LAN/server management routing, invitation setup and complete SMS notifications.

No known unaddressed P0 or P1 issue remains in these reviewed software paths.
This is a software review result, not acceptance of the untested cellular audio
adapter. Real PushKit background delivery has now been verified separately.

## Findings resolved

| Priority | Observable failure | Resolution and evidence |
| --- | --- | --- |
| P1 | Renegotiating a muted call creates an enabled microphone track. | Apply initial mute before adding the track. The production-manager Simulator regression failed before the change and passes afterward. |
| P1 | A callback or delayed end action from an old peer/call can disable a newer call. | Scope callbacks, negotiation completion, and cleanup to the call and media generation. Regressions cover peer replacement and call replacement. |
| P1 | A queued dial can execute after cancellation or expiry. | Deliver the original expiry, retain a monotonic window across queue/media waits, cancel waiting AT work, and mark submission at the port transaction boundary. Server retry and agent port-lock/deadline tests cover this behavior. |
| P1 | A late hangup for another call can cancel current media preparation. | Take a waiting command only when its call ID matches. The state-preservation regression covers matching and unrelated call IDs. |
| P1 | Stale signaling prevents a woken phone from answering; a stalled send waits indefinitely. | Check receipt freshness on wake, command readiness and heartbeat; replace stale sockets and bound sends while retaining established media. Simulator regressions cover replacement and stalled writes. |
| P1 | Historical ended events or an outgoing operation resuming after microphone permission overwrite a new call. | Process ended events without adopting them and recheck ownership after suspension. Regressions preserve the current call in both cases. |
| P1 | An installed standalone test shell prevents access to the app. | Restore the complete app; put the fixture behind explicit debug flags and a launch argument, in a sheet with Back to OpenU60. Add Back/Close to ordinary calling navigation. Normal and optional fixture builds pass; the normal app was installed and launched on L17. |
| P1 | A reconnect snapshot requests two competing media peers before either offer arrives. | Reset the previous socket's media-request marker before applying the snapshot. A focused regression fails before the change and passes afterward. The real public-service fixture reproduced the duplicate requests and `answer_set` failure. |
| P1 | A selected direct path can connect briefly, then lose connectivity and end an otherwise recoverable call. | Retry media once with TURN-only ICE while keeping the same call and mute. Simulator regression verifies no new dial or hangup, and L17 recovered a real background-push call onto `relay/udp` without completing the CallKit call. |
| P1 | Real router setup rejects the iOS `serverURL` request before enrollment. | Explicitly deserialize the caller's field name. The focused request-contract test fails with the original mapping and passes with the fix. Real U60 enrollment and L16 pairing subsequently passed through the complete App. |

The server lockfile is compatible with deployed Bun 1.3.14; frozen installation
and type checking were verified on nl1.

## Verification

- Agent: 308 passed, 4 ignored in the default suite. The two external TURN cases
  among those ignored tests passed separately earlier against the unchanged
  relay configuration.
- Server: 38 passed, 251 assertions, including management relay and full SMS
  notification outboxes. Tests pass locally and in a credential-free container
  using the deployed Bun 1.3.14; type checking passes.
- iOS management transport: verified LAN preference, router identity and clock
  checks, relay fallback, stable write IDs, explicit failures, remote revocation,
  invalid saved LAN URLs and bounded concurrent dashboard reads.
- SMS notification payload tests preserve complete text across Unicode, JSON
  escapes and multi-part messages, each below the APNs byte limit. Device tests
  cover durable queues, historical-message seeding, ID reuse and the synthetic
  notification action. These checks do not establish physical APNs delivery.
- Native PCM bridge: four synthetic frame/socket contract tests passed.
- USB charging: four targeted agent regressions cover both directions, delayed
  hardware readback, rejection of unsupported states and readback failure. The
  agent confirms state before reporting success; App polling cannot overwrite a
  concurrent switch with an older reading. A native model regression preserves
  the off control when source mode clears the CC flag and rejects missing power
  state. The status API reads the powerbank controller rather than stale charger
  telemetry. Source mode was held for several minutes and disabled through the
  App without unplugging; USB/ADB returned and hardware reported sink role.
- Production iOS manager: isolated Simulator lifecycle regressions passed.
- Actual Google WebRTC M155 SDP/ICE/DTLS with the production Rust implementation;
  three synthetic G.711 packets received by iOS in the final downlink check.
  Microphone transmission was deliberately disabled.
- L17: real Apple APNs/PushKit incoming-call receipt while backgrounded with
  signaling disconnected; CallKit answer, mute, hangup, audio activation and
  deactivation, speaker/receiver routing, and native bidirectional PCMU traffic
  against the authenticated public service and a synthetic Rust router. One
  completed call counted 3,899 packets sent and 3,007 received at the fixture.
- Updated public HTTPS/WSS: synthetic enrollment, pairing, original command-expiry
  delivery, command/result, signaling and event acknowledgement passed, followed
  by enrollment revocation.
- AArch64 musl agent/native bridge builds, normal Beexio device signing, optional
  closable fixture build, and signature verification passed.
- L16 (iPhone 16 Pro, iOS 26.4.2): complete Beexio-signed App, real U60 enrollment
  and pairing, local Home reads, automatic relay reads and a notification-test
  write on another Wi-Fi network, and automatic return to local reads passed.
  Both routes displayed fresh data without gateway edits or re-pairing.
- Real ordinary SMS APNs: a synthetic device event queued while offline was
  delivered after uplink recovery with the App backgrounded. The system banner
  showed sender and complete English/Chinese/emoji/code text. A subsequent real
  notification tap opened the Messages screen and selected the SMS tab. These
  synthetic events do not change the real SMS database.
- Invitation file import checks cover the bounded regular-file contract,
  malformed text and symbolic links. Its visible normal setup action passed on
  L16. Xcode's dedicated App ID profile includes L16 and development APNs.

## Device acceptance still required

The no-SIM acceptance used the Mac as an encrypted temporary uplink for the U60;
the phone used real ZTE Wi-Fi for local requests and its original Wi-Fi for the
remote path and Apple notifications. The temporary network configuration and
forwarder were cleaned up. L16's original Wi-Fi and two-minute auto-lock were
restored, and its owned automation job was stopped. Pairing persists, but the
router needs its own internet uplink for independent remote use.

A voice-capable SIM, carrier registration and a real U60 call are required to
verify the vendor helper ABI, PCM direction/format, cellular routing and audible
speech in both directions and actual carrier SMS receive/send. Lock-screen/terminated-app answering, Bluetooth
routing and cellular DTMF remain device acceptance items. The successful RTP
checks do not establish intelligible carrier speech or the PCM adapter ABI.

The optional fixture uses isolated synthetic router/phone credentials on the
real HTTPS/WSS service and the installed app's real VoIP token. USB-transferred
inputs stay private; the test opens no modem, saves no audio and leaves the real
pairing Keychain untouched. Its enrollment and registered token are revoked
after verification. It is not part of the distributed application.

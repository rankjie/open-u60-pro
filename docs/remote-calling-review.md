# Remote calling review

Reviewed on 2026-10-20: server authorization, command persistence and expiry;
router command ownership, cancellation and AT submission; iOS call ownership,
WebRTC negotiation, signaling recovery, CallKit actions and audio activation.

No known unaddressed P0 or P1 issue remains in these reviewed software paths.
This is a software review result, not acceptance of the untested cellular audio
adapter or proof of real PushKit delivery.

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

The server lockfile is compatible with deployed Bun 1.3.14; frozen installation
and type checking were verified on nl1.

## Verification

- Agent: 289 passed, 4 ignored in the default suite. The two external TURN cases
  among those ignored tests passed separately earlier against the unchanged
  relay configuration.
- Server: 24 passed, 89 assertions, and type checking locally and on nl1.
- Native PCM bridge: four synthetic frame/socket contract tests passed.
- Production iOS manager: isolated Simulator lifecycle regressions passed.
- Actual Google WebRTC M155 SDP/ICE/DTLS with the production Rust implementation;
  three synthetic G.711 packets received by iOS in the final downlink check.
  Microphone transmission was deliberately disabled.
- L17: real CallKit incoming/outgoing, answer, mute, hangup, audio activation and
  deactivation, and background call reporting passed with an in-memory gateway.
  The background fixture used a bounded background task, not an Apple VoIP push.
- Updated public HTTPS/WSS: synthetic enrollment, pairing, original command-expiry
  delivery, command/result, signaling and event acknowledgement passed, followed
  by enrollment revocation.
- AArch64 musl agent/native bridge builds, normal Beexio device signing, optional
  closable fixture build, and signature verification passed.

## Device acceptance still required

A voice-capable SIM, carrier registration and a real U60 call are required to
verify the vendor helper ABI, PCM direction/format, cellular routing and audible
speech in both directions. Native iPhone microphone-to-Rust RTP while CallKit
owns the audio session has not yet been established by these synthetic checks.
Real PushKit cold wake, lock-screen/terminated-app answering, Bluetooth/speaker
routing and cellular DTMF remain device acceptance items.

The optional LAN fixture is single-use, restricted to an explicit private bind
and peer address, bounded in duration, and opens no real modem or credential
store. It is not part of the deployed server or distributed application.

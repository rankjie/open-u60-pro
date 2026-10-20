# Native push and audio verification

The optional verification sheet runs inside the complete application. It uses
the production PushKit registry, CallKit provider, WebRTC media and WSS manager.
The synthetic router uses the production Rust media engine; it synthesizes a
quiet 440 Hz PCMU downlink and counts uplink packets without recording audio.
It never opens the modem or claims to test carrier speech.

Build the complete signed application with `build_native_callkit_probe.sh`, using
the normal signed app as the team metadata source and `Apple Development` as the
signing identity. The optional flag is absent from ordinary app builds.

Create a short-lived enrollment invitation with the normal server admin client,
writing it to a private file. Use `server/src/native-probe.ts prepare` to provision
isolated router/phone endpoints and private USB-transfer inputs. Transfer only the
synthetic phone input to the app's Documents directory as
`openu60-native-probe.private.json`. Do not print these files or reuse the real
router's pairing. Launch the complete app with `--native-callkit-probe`.

Run `native_media_gateway --server <synthetic-router-private-file>`. Its bounded
interactive controls are `ring`, `hangup`, and `quit`. Prepare background push
disconnects signaling; press Home, wait, then submit `ring`. The actual public
service must deliver an Apple VoIP notification. Check the real native call UI,
the background receipt counter, CallKit connection/audio activation and rising
RTP counts in both directions. Verify mute, receiver/speaker and clean hangup.
The fixture's ICE diagnostics print only candidate type/protocol and counters.

The no-SIM U60 Wi-Fi has no internet. For a cellular-only test, switch Wi-Fi off
in Settings and confirm the switch value, rather than relying on a status-bar
cellular icon: Wi-Fi Assist can show cellular while the phone remains associated
with that offline network. Restore the previous Wi-Fi setting afterward.

End the call before quitting the fixture, use Back to OpenU60, then run
`native-probe.ts cleanup <synthetic-router-private-file>` to revoke that enrollment
and its registered VoIP token. Reinstall the normal complete app. The verification
session changes credentials only in memory; the normal pairing Keychain is
untouched.

Observed on L17 on 2026-10-20: real APNs/PushKit receipt while backgrounded with
signaling closed; native CallKit audio activation; bidirectional PCMU traffic;
mute, speaker/receiver and hangup. A reconnect snapshot initially created two
competing offers; its focused regression fails before the fix and passes after
moving the media-request reset ahead of snapshot application. A real SIM, carrier
IMS, vendor PCM direction/ABI, intelligible speech, Bluetooth and terminated-app
acceptance remain separate checks.

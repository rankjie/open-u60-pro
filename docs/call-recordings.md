# Call recordings

The complete call history, including missed and unrecorded calls, is cached
separately from downloaded audio. It loads synchronously for the selected router
at launch; network refreshes reconcile records by call ID without clearing the
list. Failed pagination retains the last complete history. Deleting audio
persists its updated metadata while retaining the history entry.

U60 owns the shared call history and records both directions from the existing
PCM bridge as stereo 8 kHz PCM16 WAV: channel 0 is the cellular caller and channel
1 is the answering phone. The answering/initiating app mirrors the growing file
and retains its own copy. Other paired phones can download, play, share or delete
the router copy through authenticated LAN, P2P or the existing server relay.
The server does not retain audio. Local downloads remain available offline.

Dial and answer commands carry the initiating phone's display name and hardware
model. The service binds them to the authenticated endpoint and includes them in
the immutable command and direct-delivery admission signature. U60 persists this
attribution with the call history, and phone downloads retain it offline. The
recordings list and detail show the actual calling/answering device independently
of the recording's storage locations shown in call details. The history list
uses a waveform icon for recording availability. Legacy records do
not infer ownership from a downloaded copy: they show Device not recorded, or
Not answered for incoming calls that never connected.

Call snapshots retain the first modem-observed active time as `answeredAt`.
The normal call screen uses the system timer text from that timestamp, so audio
renegotiation and returning to the screen do not restart the elapsed time.

Recording runs on a bounded dedicated writer, independently of live audio.
Missing audio intervals are silence; queue overflow and disk failure stop the
recording with an explicit error rather than interrupting the call. At least
64 MiB is reserved for normal device operation. No old recording is automatically
deleted. WAV headers are checkpointed and repaired after an agent restart.
Call metadata is atomic, and deleting audio retains its call-history entry.
Each call also retains its original cellular number/SIM snapshot; see
[Cellular line attribution](cellular-lines.md). The number shown in History is
never taken from the currently inserted SIM.

`GET /api/recordings` and `/api/call-history` return up to 100 entries with
`nextOffset`; `/page/<offset>` reads subsequent pages. Audio is downloaded through
`GET /api/recordings/<call UUID>/audio/<byte offset>` in at most 64 KiB chunks.
`DELETE /api/recordings/<call UUID>` removes the router recording after the call
ends. These routes use the existing management validator and write journal.
`GET`/`PUT /api/recordings/<call UUID>/transcript` share an on-device-generated
transcript among paired phones. The phone persists pending uploads before the
request and retries them on foreground. Audio deletion also deletes the shared
transcript. Transcript text is limited to 48,000 UTF-8 bytes for the existing
bounded management channel; longer text remains on the phone and can be shared.

The normal iOS Calls screen places History beside its connection pill. It reads
`/api/call-history`, including missed calls and outgoing attempts without audio.
Missed calls are red; call duration uses the answered/end timestamps rather than
the recording length. Recording playback, download, sharing and transcription
live in call details when audio exists. Deleting audio retains the history entry.
The library merges router and phone copies by router/call identity and
distinguishes their locations. Apple SpeechAnalyzer provides on-device transcription on
supported iOS 26+ devices; the legacy Speech recognizer is available only where
its on-device model is supported. Language/model unavailability is explicit.

The physical UI displays incoming/active call state on Home and lock. Calls
occupies the former Upgrade menu slot, while Help retains access to the original
factory updater. Native layout admission, UI-thread ownership and the independent
factory recovery supervisor apply to these views as well.

Validation covers stereo samples, chunking, restart recovery, deletion/history,
download merging and native-renderer interaction. The normal app on iPhone 16 Pro
played and shared a synthetic stereo WAV, transcribed it using Apple SpeechAnalyzer,
retained the text across an app update, and removed its local audio and text.
The synthetic fixture was then removed. The supervised native screen passed
real touch navigation for Calls and Help; the original updater remains available.

A production-receiver regression reproduces and fixes rejection of negotiated
PCMU payload type 0: webrtc 0.17.1 can leave the track's codec cache empty, so the
receiver uses the negotiated RTP payload map. Real carrier audio and transcription
accuracy are separate from those synthetic tests.

On 2026-10-22, an outgoing Ben SIM call from the complete Beexio-signed app on
iPhone 16 Pro reached the recipient, who confirmed audible speech in both
directions. The resulting 28.18-second stereo recording contained audio on both
channels. Its 901,804 bytes matched exactly between U60 and the automatically
synced iPhone copy (SHA-256
`c6c4de5af096eb1be4fe64b9a3744b150a8780d25b466fb4dcd34639ac2c668e`).
The normal app displayed both locations and played, paused, sought and resumed
the recording. A transcript was present in the app and persisted on U60;
transcription accuracy was not assessed against a reference transcript.

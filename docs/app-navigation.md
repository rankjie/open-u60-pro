# App navigation

The normal OpenU60 app has four tabs: Home, Calls, Messages, and Settings. Home
has no navigation bar and states each reading once.

Home starts with the internet card: Cellular and the network type for SIM
Hotspot, or the upstream network and band for Wi-Fi Repeater, the connection
state, live cellular download/upload and the last minute of measured samples.
Signal, Battery, Devices and CPU tiles follow in a grid (two columns on a phone,
one row when wide), then the newest unread message thread with its verification
code. Each tile is one number and one line of facts (the Signal tile is titled
with the carrier): SINR, band and the data session's QCI (5QI on 5G SA); battery
power flow (USB input, then the battery's charge or draw, and runtime while
discharging); the hotspot name; CPU temperature. A quiet line at the bottom
shows Local, P2P or Relay for the app- to-router connection, and the data age
only once it is ten seconds old; it opens the connection-details sheet with the
current route, local address, remote pairing and server status, and the router's
internet source. Regular width (the unfolded iPhone Duo, iPad) lists connected
devices and the three newest threads side by side instead. Every signal-bar icon
(Home, signal details, Device Info, eSIM, Live Activity) shows the measured
level: 4 bars from RSRP at -80/-90/-100/-110 dBm, 3G from RSCP, and Wi-Fi scan
results by dBm. Battery percentage uses validated device telemetry. Battery
readings older than ten seconds are shown dimmed with their age. Unknown values
display a dash. Traffic rates expire after five seconds without a fresh sample
and are explicitly labeled cellular traffic when stale; the history chart is
cleared whenever the sample chain breaks rather than bridging the gap. No
generated chart or estimated reading is presented as a measured value.

A paired router's last confirmed Home readings (not traffic) are stored per
router UUID and shown at launch with their age until the first refresh. With a
saved password the app opens straight to the tabs and signs in behind them; an
unreachable router leaves it marked offline on cached state, and only a refused
password returns to the login screen.

The USB phone-charging switch stays in a small strip above the cards, only when
USB is connected. Signal Live Activity controls live inside signal details. Wi-Fi
sharing has an explicit button instead of an invisible card-wide tap target.
Wi-Fi & devices labels each band by its current role: Upstream shows the selected
network and connection state, Hotspot shows the broadcast network, and unused
bands show Disabled. Home and its detail sheets share one internet-status poller.
The Internet card shows SIM Hotspot or Wi-Fi Repeater beside its heading. The
Internet sheet omits a page title and follows the selected source. SIM Hotspot
shows carrier, the SIM-provided phone number (or an explicit not-stored state),
and cellular connection state, with
links to mobile data, network mode, APN and SIM settings. It does not scan Wi-Fi.
The phone-number row opens an editor from both Internet and SIM settings. Manual
numbers are saved on U60 by ICCID in `/data/openu60-sim/phone-numbers.json` and
shared by all connected phones. `PUT /api/sim/phone-number` takes `iccid` and
`number`, rejects a changed or unready SIM, and persists atomically. An empty
number removes the manual entry and restores the SIM-provided number. This is
display metadata; it does not write to the SIM card or change the carrier account.
Choosing **Use Wi-Fi repeater** explicitly opens upstream selection. Repeater
mode starts with the upstream → U60 → hotspot diagram, then the selected bands
and network list. Accessibility text sizes use a vertical path.

Settings groups device networking, cellular/SIM, security, and system controls.
Hub rows show the last known state (connected devices, network type, battery,
unread messages, connection route) without issuing requests of their own; opening
Settings before Home has polled triggers one batched refresh. Settings screens
report progress in the navigation bar and results in a bottom banner: errors stay
until dismissed or replaced, confirmations fade after four seconds.
Service settings contain message notifications/forwarding, schedules, diagnostics,
and advanced tools. App connection, appearance/refresh, and About have their own
pages. Common actions precede radio locks and other advanced settings. Tools that
only displayed a placeholder are omitted. Existing working tools remain available.

Calls owns the dialer, in-call controls, and connection/pairing sheet. Its server
row and Home's connection details lead to one shared server list with manual
selection and address management. Empty Call recalls the selected U60's latest
outgoing number without dialing; another tap places the call. Incoming numbers
are not used for recall. History includes incoming, outgoing and missed calls;
the dialer shows the current U60 line, while History and individual SMS retain
their own number/SIM snapshots from the event. Old entries without a snapshot
show Line unknown, and a card without a stored number shows its SIM suffix.
recordings belong to individual call details. Star and pound have independently
centered glyphs, with keypad dimensions based on the physical iPhone's Phone app.
A valid CallKit answer requests the current
call screen immediately, before microphone permission or the modem response.
The request survives creation of the authenticated tab view, selects Calls,
clears its history navigation path and closes its connection sheet. Returning
to the app during a call or restoring an ongoing call requests the same route;
ordinary ringing snapshots do not repeatedly interrupt navigation. Ending the
call clears the pending presentation request.

On 2026-10-22, a real incoming call on L16 verified notification-answer
navigation in the complete signed app: Settings was selected while the Calls
stack retained a recording detail, and answering from the system banner opened
the current call controls directly. The isolated lifecycle checks cover the
answer request before asynchronous work, repeated ringing snapshots, foreground
reopening, restoration of ongoing calls and stale actions after call end.

Messages shows an unread badge on its tab, updated by push delivery as well as
list reads. Threads from service senders are named by their signature (for
example 【京东】), which is removed from the preview. A 4–8 digit code within 40
characters of a code keyword is offered as a one-tap copy chip on the thread row,
in the conversation and on Home, for incoming messages from the last day. The
SIM line is shown on rows only when the inbox spans more than one known line, and in a
conversation only where it starts or changes. At regular width Messages is a
split view of threads and the open conversation. Message
settings have one shared destination from Settings and the contextual Messages
menu. Messages always shows all storage locations together. Compose and message
screens keep explicit keyboard dismissal and normal back/cancel navigation.

History and Messages restore a persistent, router-UUID-scoped cache before any
network request. Returning to either page reuses a successful refresh for 30
seconds; pull-to-refresh and a new SMS notification bypass that window. Requests
run with existing rows visible. List reconciliation inserts, updates, moves and
removes only affected IDs; unchanged records are left in place. Complete history
pagination is required before reconciling removals, so a failed later page cannot
truncate the cache. Network errors and cancellation retain cached content.
Acknowledged message reads/deletes and recording deletion update the cache too;
an older request cannot undo them. A router change clears the previous device's
visible rows and loads that router's cache. Devices used only through local login
still support SMS; disk caching starts once a stable router UUID is available
through pairing, rather than treating a reusable LAN address as device identity.
Cache files use atomic writes and iOS file protection; malformed or unwritable
files surface an error and can be repaired by a successful refresh.

Verification on 2026-10-21 used the complete Beexio-signed app on L16, without
verification-shell build flags. Build, native navigation, light/dark layouts, and
management via the deployed server were checked. Multi-phone ringing, exclusive
answer ownership, reconnect behavior, and per-phone SMS/VoIP retry persistence
are covered by server and isolated native lifecycle tests. Simultaneous real
PushKit/CallKit operation on L16 and L17 still needs device tests.

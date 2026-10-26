# Wi-Fi internet modes

The iOS app keeps hotspot settings separate from the internet source:

- **SIM hotspot**: the firmware's existing cellular uplink and hotspot settings.
- **Wi-Fi repeater**: the selected band connects upstream; the other band runs the existing local hotspot. IPv4 NAT shares one upstream address.

Tap an upstream network to enter its password or confirm reconnecting to a saved
network. Connect applies the change immediately. **Other…** below the list opens
an SSID/password sheet with **Auto** security selected; manual security options
remain available. The list groups APs with the same SSID on the selected band,
and shows loading while scanning. **Use SIM hotspot** returns to cellular mode.
MAC cloning, TTL, and the management address are in Advanced.

Camouflage clones a user-selected device MAC onto the upstream interface. An optional fixed IPv4 TTL is applied on that interface only. The source device must disconnect from the upstream network before cloning its MAC. This is not a guarantee against every network's device detection.

The firmware's `sta_connect`/scan ubus methods refer to an absent `/sbin/wifi_sta_opt.sh` on the inspected MU5250 firmware. The agent therefore owns a bounded station worker using the installed nl80211 driver, wpa_supplicant and netifd DHCP client. Factory wireless configuration and generated hotspot credential files remain with their existing firmware clients.

## Lifecycle and API contract

`GET /api/wifi/uplink` returns redacted settings, connection state, the latest asynchronous operation and scan results. `PUT /api/wifi/uplink` admits a mode change and returns an operation identifier before changing wireless interfaces. `POST /api/wifi/uplink/scan` scans on the requested band without switching modes. `POST /api/wifi/uplink/portal` refreshes captive portal detection.

One worker serializes changes and scans. Configuration is persisted before an admitted change; status exposes pending, connecting, connected, captive, disconnected or failed. Association/DHCP waits and child commands have deadlines. A failed mode switch restores the factory hotspot runtime and reports the original failure and any recovery failure. Mode changes do not alter the USB mode; the firmware's full wireless restart can recreate its network interfaces, while ADB remains the recovery path. Reconnects use wpa_supplicant's normal network selection; restart recovery uses the saved profile. Stale control sockets left under `/data` after a reboot are removed only after the kernel confirms that no daemon is listening.

At startup, recovery waits up to 90 seconds for the vendor driver to create both
wireless interfaces before attempting a mode change. The home Internet card and
the Wi-Fi page poll the same uplink status independently of cellular statistics.
They retain the selected upstream name on failure, distinguish an unavailable
status from a disconnected uplink, and provide a saved-network reconnect action.

When automatic time is enabled, an online Wi-Fi uplink synchronizes the Linux UTC
clock through the configured primary NTP server. The server name is resolved
through the uplink's DHCP DNS servers first (3 s each), then the system resolver
(5 s), because the system resolver may still forward to cellular DNS right after
the switch; a literal IPv4 server needs no lookup. DNS and UDP waits are bounded;
reply validation checks the source socket, request timestamp, mode, version,
stratum and synchronization state. Failures remain visible in uplink status and
retry no more often than once per minute. Successful synchronization is refreshed
hourly or after an unexpected wall-clock jump. This avoids the inspected vendor
time client's cellular dependency and its observed timezone offset in the kernel
clock, which otherwise prevents TLS/signaling after a reboot.

Portal detection fetches `https://www.apple.com/library/test/success.html` through the station interface with redirects disabled; only a 200 carrying Apple's success body counts as online, so it also works where Google is unreachable. A redirect or a different page is a captive portal; a portal that breaks TLS reads as limited. Only HTTP/HTTPS links without embedded credentials are offered. Open the login page while the iPhone uses the U60 hotspot so the login authenticates the U60's upstream connection. Recheck connectivity after authentication. While the Wi-Fi uplink is selected, an owned rule bypasses the firmware's no-SIM HTTP redirect for downstream hotspot clients; returning to SIM hotspot removes that rule.

Upstream passwords are input through the normal app, held in the agent's private profile and the supplicant's private runtime file, and omitted from responses and command arguments. Switching modes preserves the hotspot SSID/password. An upstream subnet overlapping the U60 LAN is an explicit error with instructions to change the LAN address.

## Verification

Focused tests cover mode/band/security validation, WPA configuration escaping, MAC cloning, scan parsing, portal redirects, operation ownership and failure recovery. Native builds and real device tests distinguish driver capability from successful association, DHCP, NAT and captive portal authentication. SIM cellular traffic and a real public portal require their respective networks.

The device has associated to a 5 GHz upstream, obtained DHCP, passed a bound
internet probe, and forwarded an iPhone's HTTPS traffic through its 2.4 GHz
hotspot. An iPhone on that hotspot also loaded Apple's HTTP connectivity page
successfully without the firmware's no-SIM redirect. A clean reboot restored ADB
automatically at 33 seconds, and restored the uplink and correct UTC clock by
60 seconds. The normal app displayed the upstream and Online through both local
and server connections. Public captive portal authentication and SIM traffic
remain untested.

DHCP isolation was checked with three upstream DHCP discovery probes and
simultaneous packet capture on the Mac's upstream LAN and the router's station
interface. All three observed replies came from the upstream DHCP server; the
U60 emitted no server replies. The native DHCP pool is bound to `br-lan`, the
station is not a bridge member, and upstream input admits DHCP client replies
(UDP 67 to 68) while rejecting unsolicited server requests. This verifies the
inspected running repeater configuration.

MAC cloning was checked with an unused synthetic unicast address. The driver
adopted it, DHCP and internet recovered, and restoring the original settings
restored the original driver address and online upstream. No existing client's
address was duplicated during the test.

## Native touchscreen

The touchscreen extension reuses native LVGL controls and the original UI thread.
Its Home panel shows the upstream name, connectivity and measured Wi-Fi rates
without changing SIM state. It waits for the factory Home layout and hides on
lock, network selection and other factory pages. The original screen files stay
intact; a separate supervised boot service can be installed or reverted.
Supervised trials maintained live uplink/rate status and returned to the factory
service at their two-minute deadline. The owner confirmed opening the network
list on the physical touchscreen. A complete evdev test also scanned, opened
Other, returned, selected the saved upstream and reconnected to L_5G/Online,
then returned to the factory home. Queued and in-flight requests keep scan/loading
state and controls consistent until a fresh service response. A factory `shutdown` image symbol
collision found during startup was reproduced in the isolated real-RPC test and
fixed with explicit socket-function resolution.
Verified copies of the original program, SDK and startup now live on both the
router and Mac. The independent recovery process supervises the extension while
preserving the original screen files. Bounded trials keep the original boot
path, publish a UI-thread heartbeat, and expire back to the factory service
within two minutes; process/heartbeat failure also triggers recovery.
Live numeric Home rates were verified on the device. The factory update check
completed over Wi-Fi and reported no update; no firmware was installed.
The production extension also passed orderly boot recovery: ADB returned at
about 55 seconds and the saved Wi-Fi uplink, native UI heartbeat and correct UTC
were available by about 80 seconds. Touchscreen actions restored both factory
hotspot bands and then rejoined the saved L_5G uplink with live numeric rates.
Manual revert removed only the owned startup line and restored the factory UI;
forced guardian termination automatically disarmed the extension and restored
stock without rebooting the device. The installer uses the firmware's existing
`rc.local` path with byte-preservation checks, matching the ADB startup path.
See [native touchscreen status](../native/wifi-ui/README.md).

# Native touchscreen Wi-Fi

The extension uses the inspected MU5250 firmware's statically linked LVGL and
original UI thread. Its 55 native controls provide upstream scanning, grouped
network selection, saved-network confirmation, masked password input, Other
with Auto security, and confirmed return to SIM hotspot. The SIM action has a
mode-switch icon and explains that switching disconnects upstream Wi-Fi and
uses the SIM for internet. Cancel and locking dismiss the confirmation without
an apply request; a pending Wi-Fi operation disables confirmation.
It does not intercept DRM or input.
The native lock/modal layers hide the entry and clear private input.
The entry is a normal **Wi-Fi 中继** row in the factory Wi-Fi settings list,
after its Wi-Fi and band-steering switches. It uses the inspected factory button class and
the list's existing scrolling layout; Back returns to that list. Its owned
deletion observer recreates the entry when the factory rebuilds Wi-Fi. Binding
waits for the pinned route-6 layout, with the same bounded 20-second layout
deadline as Home. An unsupported layout fails into independent stock recovery.
Binding identifies the visible body by geometry and widget classes because
cached submenus change the factory's child order. The list's scroll extent
includes the new row so the last original option remains accessible.

The Wi-Fi pages use Chinese labels, the native active font family's 20/16 px
text, dark gray rounded rows and the native 42 px header. Input masks, connection
values and backend error detail remain intact. Home shares the factory lock's
wallpaper, type and upload/download layout. The factory status bar remains visible above each page. See
[the visual contract](../../docs/touchscreen-design.md).

The Home menu's Upgrade slot opens **通话** and its paged call history. **帮助**
contains the original help and firmware-update entries. Child controls consume
their clicks without bubbling into the preserved factory tile; selecting an
original entry dispatches its original callback explicitly. A non-interactive
incoming/active call banner appears on Home and the lock screen, and hides over
PIN, modal and other factory pages. Call data comes from the agent's existing
private local UI socket. The same layout admission, deletion recovery and
independent stock supervisor cover these pages.

For a local preview without installing anything on the router:

```sh
python3 tools/render-touchscreen-preview.py
python3 -m http.server 8766 --bind 127.0.0.1 --directory target/wifi-ui/preview
```

Open `http://127.0.0.1:8766`. Images come from the actual pinned LVGL renderer
and synthetic state, including the real C Home view, keyboard and QR rendering.
The gallery's clickable regions demonstrate navigation; they are not a running
router or editable keyboard. `--factory-home` optionally accepts an explicitly
inspected, credential-free 320×480 P6 Home reference for the preserved status bar
and carousel dots. It does not connect to or capture the device.

The network list also opens **连接 App**, which displays a QR code containing
the stable U60 connection string and configured server. Choose **Scan U60 QR code**
in the normal iPhone app: it selects the server and connects with the saved router
password, or focuses the password field if none is saved. The string and server
remain below the QR for manual entry. The page
reads only public connection metadata through the existing private local UI
socket; passwords are entered in the iPhone app. Its rendering, Back action and
lock behavior use the same native controls and recovery supervisor. The pinned
LVGL tests and live metadata RPC verify this addition. Apple Vision decodes the
actual pinned-LVGL QR render into the App's device/server parser. Physical camera
scanning still needs acceptance.

The Home carousel has a Wi-Fi internet panel showing the upstream name, online
state and measured upload/download rates. It reuses the lock's Earth image,
64 px numeric family, yellow upload and green download images with separate
units. The Chinese heading and upstream name occupy the lock's two-line notice
area. Missing samples show `--`; zero is shown only for a valid zero sample.
It covers the cellular-only first page while repeater mode is selected; the factory controls and real SIM state
remain intact. It hides on lock, native Wi-Fi selection and other factory routes.
Binding waits for the original Home layout, with a 20-second deadline.
The visible body's geometry identifies Home after returning from Wi-Fi because
cached factory forms shift its child index. Its first carousel content retains
the separate inspected geometry and child-count admission checks.
The overlay observes LVGL deletion before factory objects are freed. Clearing or
replacing Home releases the binding and creates one fresh panel on the next
recognized Home page, including when the factory rebuild happens behind the lock.
The pinned-LVGL regression exercises both a cleared page and a replaced owner.
Factory cleanup of one custom page or the entire top layer likewise invalidates
all custom control bindings. The next UI-thread refresh removes only surviving
owned roots, clears private editing state and recreates one usable set of pages.
A recognized replacement factory screen rebinds its lock/modal layers instead
of leaving the extension permanently hidden.
Unchanged text, visibility and control styles do not invalidate the display.
Pinned-renderer checks require zero extra flushes for an unchanged Home/network
list and a new flush when a network error changes.

The lifetime separation is informed by
[u60pro-devui's independent presentation and IPC](https://github.com/33333s/u60pro-devui).
The existing factory controls and screen/input owner remain in use; its unrelated
installer and backend are not installed. See
[the failure boundary and acceptance checks](../../docs/touchscreen-stability.md).

Supervised two-minute device trials passed. The owner confirmed opening the network list
by physical touch. A subsequent evdev test completed scanning, Other/Back,
saved-network selection, actual reconnection to L_5G/Online and return to the
factory home. Live status and station rates advanced throughout the trials.
The live Home panel displayed Online and changing numeric rates on the device.
Only the four inspected updater availability queries substitute online Wi-Fi for
the modem dial state. The stock lock renderer independently requires a ready
cellular state before displaying rates, even after reading valid Wi-Fi counters.
The lock formatter's inspected SIM/dial calls and local cached-connection getter
accept associated upstream traffic with fresh samples, including behind a
captive portal. The factory formatter then draws, sizes and aligns its own rate
labels. Other SDK consumers and the cached cellular model retain the real state.
Stale/disconnected samples and SIM hotspot use the original gates. A separate
non-interactive lock card shares Home's renderer for upstream name, connection
state, sampled rates and active hotspot SSID. Its opaque background prevents
the native notice's partial redraws from affecting the added text. It ends
above the factory notification, lock icon and long-press affordance.
The UI worker obtains hotspot metadata from the opposite radio's
hostapd `STATUS` control request with a one-second deadline and an abstract
reply socket. It never reads wireless configuration or keys. Disabled and
unavailable hotspots have explicit labels. The factory cellular notice is not
modified and reappears when the overlay hides in SIM hotspot mode. The lock's
fonts and image assets are reused. Notification controls, PIN/transition and
input handlers remain factory-owned. Factory deletion clears the lock binding;
the next refresh recreates one card on a recognized 14-child lock body.
The local getter is not dynamically exported: its one pinned process-local GOT
entry is rebound only after checking the original target, and RELRO is restored
immediately. Failure aborts the candidate for guardian recovery. Neither on-disk
firmware nor the cellular model is modified; stock restart maps the original
getter again. The real-renderer regression verifies gate scope, preservation of
the model/SDK errors and read-only page protection.
The factory check completed over Wi-Fi and reported no update. No firmware was
installed. The production extension passed orderly reboot, default ADB, saved
upstream and UTC recovery, factory-hotspot/repeater switching, manual revert
and procd recovery after a forced guardian termination.

`/tmp/openu60-native-ui.status` exposes numeric/boolean health metadata only:
UI-thread sequence, native page/lock/busy state, station rates and factory reader
coverage. In a no-SIM factory-home sample the station rates were valid and an
ordinary unbound HTTP probe returned 204, but `factoryRateReads` stayed zero.
Receiving a station sample therefore does not establish that the factory speed
view consumes it. `factoryRateViews` distinguishes the three inspected speed
views and the status bar; `factoryUpdateChecks` counts the inspected update gates.
`wifiHomeVisible` reports the Wi-Fi Home panel's logical visibility, and
`factoryForm` identifies the active factory route. Home's second carousel page
clips the panel naturally when it scrolls out of the viewport.
`recovery/last-result` durably records the guardian's last fixed state/reason and
the monotonic time within that boot. It contains no configuration or input.
Completed supervised sessions also record their last sequence, runtime and age
of the last advancing heartbeat to distinguish startup failure from a later stall.
An explicit extension failure publishes a fixed PID/code pair to
`/tmp/openu60-native-ui.fault`; the guardian accepts only its current child's
known code and records the corresponding fixed reason. A blocked UI thread still
uses the heartbeat deadline. This distinguishes layout/init/publication faults
from a thread that no longer runs, without logging UI contents.

The stock input driver uses evdev and rotates coordinates by 180 degrees. Its
touch-down parser accepts tracking ID zero; the kernel filters unchanged axis
values, so repeated synthetic contacts must emit a position update. Reference
material for another firmware using TUIO does not establish this input path.

## Recovery boundary

The factory executable and SDK are never patched in place. The recovery tool
accepts only the inspected firmware hashes and keeps immutable copies of the
program, SDK and init script on the router and Mac:

```
sh native/wifi-ui/build-recovery.sh
python3 tools/install-touchscreen.py --serial SERIAL --prepare-recovery
```

Router copies are in `/data/openu60-ui/recovery`; Mac copies are in the ignored
`firmware/ui-recovery/7a158227890d` directory, outside build output. Preparation
verifies all hashes and installs the standalone, statically linked recovery
process. It does not restart the screen or change its startup script.

`python3 tools/install-touchscreen.py --serial SERIAL --restore` atomically
restores and syncs the factory startup **before** requesting a bounded service
restart. A disconnect or restart timeout cannot leave a trial enabled at boot.
The original pre-guard recovery path remains available for the failed prototype.
Confirm the display and touch on the physical device after any service restart.

## Supervised boot service

Build both components and install with:

```
sh native/wifi-ui/build-recovery.sh
sh native/wifi-ui/build-native.sh
python3 tools/install-touchscreen.py --serial SERIAL --install-native
```

The inspected firmware does not execute newly enabled `rc.d` entries. The
installer starts the separate `openu60-screen` procd service through the existing
`rc.local` path, as the ADB installer does. The mixed startup file stays opaque;
round-trip hashes prove that the owned line is the only byte change. Registration
output is captured in `/tmp/openu60-screen.boot.log`. The service
uses the same startup and heartbeat deadlines as a trial. Installation requires
an advancing UI-thread heartbeat. Component publication and activation share
the guardian's exclusive lock; staging cannot replace a running guardian or an
enabled candidate. A trial requires restoring/disabling the boot service first.

`enabled.sha256` records the admitted candidate. Before stopping stock, the
guardian durably creates a `running` latch. A clean service stop restores stock
and clears the latch while preserving enablement for the next normal boot.
Process exit, a stalled heartbeat, manual restore, or an unclean previous session
disarms the candidate before restoring stock. An uncatchable guardian death also
kills its child; procd respawn observes the latch and restores stock. Power loss
likewise disables the extension on the next boot rather than retrying it.

`--restore` removes the owned startup line, stops the extra service and durably disarms the candidate.
The factory executable, SDK and init script retain their inspected contents.

## Bounded trial

Build with `sh native/wifi-ui/build-native.sh`, then run
`python3 tools/install-touchscreen.py --serial SERIAL --trial-native`.
The installer checks the remote completion marker because this firmware's ADB
transport can return zero for a failed remote command. Trials enforce:

- The candidate lives at a separate `recovery/trial.so` path and must match the
  explicit SHA-256 passed to `guard trial SHA256`.
- The guardian runs independently of ADB and the screen process. It stops the
  original service, launches one candidate process group and restores the factory
  service after at most two minutes. A trial never writes boot enablement.
- It waits for the stopped factory process to release display/input before
  launching the candidate, preserves the original null standard streams and
  disables core dumps.
- The extension must remove `LD_PRELOAD` from its environment before starting
  children, and publish `PID SEQUENCE\n` to `/tmp/openu60-ui.heartbeat` **from the
  native UI thread**. A worker-thread heartbeat does not establish UI health.
  Startup has a 20-second deadline; subsequent heartbeats have a 5-second deadline.
- Process exit, missing/stalled heartbeat, a recovery request or a handled
  SIGTERM/SIGINT/SIGHUP stops the candidate process group and restores the original
  screen. Child commands have independent deadlines.
- The original init script stays byte-identical throughout the trial, so a reboot
  always starts the factory screen. Power loss cannot persist the candidate.

`/data/openu60-ui/recovery/guard restore` requests recovery from a running
supervisor, or restores the factory service directly when no trial is active.
An uncatchable guardian termination kills the candidate through Linux's
parent-death signal; the manual restore command or a reboot then starts the
factory screen. Userspace recovery cannot repair a wedged kernel or display/touch driver; that
case may still require a physical restart. The preserved boot path prevents the
candidate from being loaded again on that restart.

`python3 native/wifi-ui/test_recovery.py` checks healthy trial expiry, startup
failure, UI-heartbeat stalls, process exit, manual restore, supervisor termination,
checksum admission and durable restore despite a hung restart using synthetic
firmware and real child processes/signals. These checks do not prove physical
display or touch behavior. On-device preparation/status checks verify the real
firmware and backups without activating a candidate.

All 22 recovery tests passed in an ARM64 Linux container, including delayed or
stubborn factory process exit, parent-death behavior, procd-style recovery,
durable enable/disable, concurrent shutdown signals and exclusive component publication. Ten installer tests
cover heartbeat admission, completion markers and opaque startup-file edits,
including idempotent add/remove, exact byte/permission preservation and rejection
of unsupported input without changing it. On-device failed startup
and healthy trial expiry both returned to the original service. Factory hashes,
the touch device node and the online repeater state were checked after recovery.

## Isolated native LVGL validation

`lvgl_abi.h` records the inspected executable's private functions. This firmware
links LVGL statically; exported APIs from a different router cannot be reused.
`abi-probe.c` replaces the original main function only inside a container and
registers a memory display with the real firmware renderer. It checks object
geometry, copied label text, click callback target/code/user data, visibility,
and RGB565 rendering. It does not run the original hardware initialization.

With the firmware ELF-only runtime already collected under
`target/device-ui/runtime-root`, run:

```
sh native/wifi-ui/test-native-abi.sh
sh native/wifi-ui/test-native-panel.sh
sh native/wifi-ui/test-native-mainloop.sh
```

That runtime contains the factory executable, its public shared-library
dependencies, loader symlinks and the public `/usr/ui/fonts/ZTEZhengYuan.ttf`
and `/usr/ui/fonts/Zoswald-Medium-24.ttf` resources at the same relative paths.
Their pinned SHA-256 values are verified before
the renderer runs. The isolated font fixture uses the factory font manager to
load the Chinese family; production uses the already active family and never
replaces its descriptors. Never copy router `/data`, configuration files,
generated QR images, passwords or push keys into it. The container mounts the
runtime read-only and has no external network or device access. The panel probe
checks real pointer hit-testing with the display's rotation, native callbacks,
input masking, printable ASCII keys, the 64-character WPA2 key boundary, apply
payloads, relock cleanup and rendering. The main-loop
probe executes the original loop instructions with a memory display and a real
worker-to-Unix-socket exchange using a synthetic status service. A delayed scan
response verifies that controls remain disabled between dispatch and fresh
remote status; queue consumption alone cannot finish an operation. Its explicit
completion marker is required; a factory hardware-initialization exit is failure.

The factory exports a data object named `shutdown`, colliding with the POSIX
socket function. Resolve the socket function after the extension with
`RTLD_NEXT`; ordinary symbol binding jumps into that image resource. The real
RPC probe reproduces that crash when direct binding is used.

Do not preload the quarantined `libopenu60-ui.so` on this device. The only
candidate is `libopenu60-native-ui.so`.

# Touchscreen lifecycle and recovery

The factory binary and SDK remain immutable. Custom network and connection-code
pages run on the factory LVGL thread under the independent recovery supervisor.
Every admitted candidate must retain automatic stock recovery and manual revert.

## Current failure

The device recorded `UI heartbeat stopped` and restored the stock service. A
subsequent two-minute locked-screen trial completed normally. That record proves
recovery, but does not distinguish a blocked factory handler from an extension
which deliberately stopped publishing health.

The extension retained Home object pointers across factory page
lifetimes and rejected a changed owner. That is a reproduced lifecycle defect;
it is not yet proof of the reported device incident's cause.
The same problem also affected custom top-layer pages: clearing their factory
parent reproduced a segmentation fault in the pinned renderer. A partial page
deletion and an entire layer cleanup now both rebuild the owned controls safely.

## Change

- Observe native object deletion on the UI thread, discard all associated
  pointers before the factory frees them, and bind a newly constructed Home page.
- Invalidate and rebuild deleted custom page roots after factory cleanup returns,
  clear the editing session, and rebind validated replacement lock/modal layers.
- Keep custom pages separate from the factory page content. A recognized page
  change must not become a UI restart; an unsupported layout still fails with a
  bounded, explicit reason rather than touching unknown controls.
- Avoid unchanged label/style/visibility updates: the pinned LVGL otherwise
  reallocates text and invalidates the view on every poll.
- Publish only fixed failure codes and the UI PID to the supervisor. Persist the
  matching reason plus sequence, runtime and heartbeat age before restoring
  stock. No page text, configuration, QR value or private input enters recovery
  diagnostics.
- Preserve the existing startup and five-second UI-heartbeat deadlines. Never
  replace a UI-thread heartbeat with a worker-thread heartbeat.

The reference is [33333s/u60pro-devui](https://github.com/33333s/u60pro-devui),
inspected at `d1d0856e19d58a2a98104e47afbdcfc51e1dc3d1`. Its standalone
DRM/evdev renderer and local IPC isolate custom presentation from vendor page
internals. Its installer is not used: it owns a different startup/backend tree.
The present change applies the lifetime separation without replacing existing
factory settings, lock behavior or the tested network backend.

## Acceptance

The pinned factory-LVGL harness must delete and rebuild a Home page, revisit it,
lock/unlock, and render current network/rate data without stale pointers or
duplicate overlays. Recovery tests must distinguish an explicit extension fault
from a stalled thread and still restore stock in both cases. A bounded device
trial must exercise screen off/on, unlock, custom-page navigation and fresh
status before permanent activation. Failure disarms the candidate first and
returns to stock. A short passing trial does not establish long-term stability.

The lifecycle regression failed before the change at factory page deletion and
passes after the deletion observer/rebinding change. The renderer checks also
prove that an unchanged Home/list does not submit another display flush, while
a changed network error does render promptly. Native controls and the
real factory main-loop harness pass. All 22 recovery tests pass in ARM64 Linux,
including matching-PID faults and foreign/unknown fault rejection. A supervised
device trial exercised network scan, connection QR, Back/Home, screen off/on and
unlock with one PID and advancing UI-thread health throughout. The final
candidate completed three successive cycles, including Other/Back. The device's
upstream remained online. Real touchscreen acceptance by the owner and longer
running time remain separate from these bounded checks.

One earlier supervised activation also timed out and returned to stock before
the richer session diagnostics were available. The sampled retry subsequently
ran for three minutes before an intentional restore. No blocked-thread trace
from the failed activation was retained, so that incident's exact cause remains
unconfirmed; the lifetime defect and repeated redraws are independently proven.

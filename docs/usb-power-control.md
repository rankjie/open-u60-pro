# USB phone charging

Home shows a compact Charge phone switch when the USB cable is detected or the
powerbank controller remains enabled. Cable attachment never presents a sheet.
Home's bottom Battery & power card shows measured battery draw and the USB
output contract when available; see [telemetry semantics](battery-power.md).
Turning the switch off returns the port to normal input/data negotiation with
the same cable attached; it does not change the configured USB mode.

The inspected firmware can clear `typec_cc` and retain stale
`otg_powerbank_state` charger telemetry while reverse power is active. Therefore
`GET /api/usb/status` adds `powerbank_state` from
`zwrt_bsp.powerbank.get({"property":"state"})`. The UI uses that authoritative
0/1 state, preserves the off switch while it is 1 and rejects missing or invalid
state. An older agent's missing state is explicit; Settings → Power & system →
USB Mode still offers Turn off phone charging so an upgrade never requires
unplugging to recover USB/ADB.

`PUT /api/usb/powerbank` accepts only `{"state":0}` or `{"state":1}`. After the
vendor set operation, the agent checks controller readback up to ten times with
100 ms between attempts. Success returns the confirmed state. Set/read errors,
invalid readback and failure to change state return explicit 503 errors. A stale
poll cannot overwrite an in-flight or recently completed switch operation.

L17 and the connected U60 were tested on 2026-10-20. Holding source mode for
several minutes reproduced the old disappearing-control bug. Disabling it through
the complete App restored ADB without unplugging. The controller read 0 and the
Type-C port reported sink afterward. At 100% battery this establishes the input
role, rather than proving a particular charging wattage. Four agent regressions
and the native USB status/control regression cover the state contract.

## Battery and router-runtime reserve

Home's Charge phone row has a Power reserve settings button. USB Mode exposes the
same settings. Minimum battery (1–100%) and router-only runtime (1–2880 minutes)
are independently optional. Both are disabled on upgrade until explicitly saved.
Either threshold stops output; it never starts again automatically.

`GET/PUT /api/usb/power-reserve` reads/replaces the complete policy. PUT requires
both `min_capacity_percent` and `reserve_minutes`, using null for a disabled
limit. `GET /api/usb/status` also includes `power_reserve`, with the policy,
baseline readiness, estimated router-only runtime, last stop, pending stop and
error. Settings and stop intent live in `/data/openu60-power/reserve.json`;
this file contains no credentials. One mutex owns configuration and hardware
writes, and the existing atomic writer fsyncs the file and directory.

Runtime reserves use measured router load **with USB output off**. On battery,
this is battery discharge power. On USB input, it is measured input power minus
net battery charging power, including conversion losses. At least three samples
spanning ten seconds are averaged over the latest minute. The baseline must be
recent when output starts and remains fixed during that output session, so an
external device's load cannot contaminate the router-only estimate. This is an
estimate based on the preceding load, not a guarantee under later network loads.

No reliable baseline prevents starting output with a time reserve. Enabling a
time reserve during an existing uncalibrated session stops output so it can be
measured. Missing battery readings stop protected output. Corrupt settings remain
an explicit error and block enabling; manual off remains available.

The device worker checks active output every five seconds and listens for power,
charger, resume and policy events. Its timed kernel wake lease prevents suspend
during protected output and initial calibration. The lease expires after process
death. Stop intent is persisted before the BSP operation; failed stops are
retried, including after agent restart. A failed save prevents manual enabling;
an emergency stop is still attempted if a threshold is reached while storage
fails. Errors stay visible. Existing BSP state readback confirms the off state.

On 2026-10-22, the complete App on L16 saved both reserve settings, calibrated
router-only load, and enabled USB output. Raising the battery reserve to the
current 100% charge stopped output automatically: the BSP read back state 0,
the saved stop reason was `minimum_battery`, and USB input resumed without
unplugging. The temporary thresholds were then disabled again. The runtime
estimate was observed on hardware; its threshold, baseline freshness and retry
behavior are covered by regression tests; a full discharge test has not been run.

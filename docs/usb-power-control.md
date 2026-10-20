# USB phone charging

Home shows a compact Charge phone switch when the USB cable is detected or the
powerbank controller remains enabled. Cable attachment never presents a sheet.
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

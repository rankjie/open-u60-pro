# Battery and USB power telemetry

Home ends with a Battery & power card, refreshed by the existing two-second
health poll. Tapping it opens details. Readings older than ten seconds are hidden
instead of continuing to look live.

`GET /api/battery` retains its existing fields and adds `charge_full_uah`,
`current_avg_ua`, `usb` and `telemetry_errors`. Core read failures return 503.
Unsupported optional sensors return null; malformed or unreadable optional
readings also identify the problem in `telemetry_errors`.

- Battery power is `voltage_now × current_now`, converted from µV and µA to W.
  Positive current charges the battery; negative current drains it. Battery draw
  includes the router, USB loads and conversion losses. It is not USB output.
- Remaining mAh is **estimated** from fuel-gauge percentage × `charge_full`.
  The kernel's relative `charge_counter` is not treated as absolute remaining
  charge. On the inspected unit, full charge reports 10,214 mAh; nominal capacity
  reports 10,000 mAh.
- Runtime is estimated remaining mAh / recent average discharge mA. The firmware
  exposes hardware-averaged current at `battery_zte/current_avg_mbb` in mA.
  Estimates require discharging state and at least 50 mA of both instantaneous
  and average drain, to exclude near-zero noise and stale charging transitions.
  USB input suppresses runtime; estimates are rounded down to five minutes.
- USB input uses `usb/voltage_now` and `usb/current_now` only while Type-C reports
  sink and USB is online. The UCSI source descriptor's advertised current is not
  a load measurement.
- In source mode, `powerbank_zte/debug` reports `request power: <mV>mv <mA>ma`.
  Its product is the **negotiated output limit**, not measured output. Zero
  voltage means no negotiated contract. The inspected firmware does not expose
  an independent live output current, so the App explicitly says live USB power
  is unavailable. Input readings are never reused as reverse-output readings.

On 2026-10-22 the attached U60 was full and receiving USB power: about 4.479 V
at the battery with a few mA of negative current, versus about 4.954 V × 0.356 A
at USB input. Vendor time-to-empty was unavailable and the generic kernel
time-to-empty value was unsuitable for an externally powered device. These
observations do not validate runtime under a sustained load or USB output
accuracy against an external power meter.

Units and charge-counter semantics follow the
[Linux power supply ABI](https://www.kernel.org/doc/html/latest/power/power_supply_class.html).

## Direct chip access investigation

The attached Type-C controller is named `sy6998` on I²C bus 2 at address 0x6b,
bound to `usb_type_c`. Silergy identifies SY6998QEQ as SY20798QEQ. Its published
register map has power/port status, voltage programming and current-limit
programming; it does not document an output-current ADC. Registers 0x81/0x82
program voltage and 0x83 programs the boost current limit. Reading those values
does not turn the negotiated limit into an actual current measurement.

The BSP exposes its register reader through `powerbank_zte/read_reg`; no raw
I²C force-access, driver unbinding, PMIC register write or regulator change is
needed to inspect the published path. The live PM7550BA IIO device also exposes
`iin_fb` and `ichg_fb` feedback channels. Their relationship to the separate
reverse-power path needs a controlled load comparison before any output-power
claim. Raw feedback values are not presented as calibrated USB output power.

A 2026-10-22 capture first switched USB roles with the Mac attached, then
repeated the measurement while the user charged a phone. During the phone's
60 samples with powerbank output enabled, `usb/current_now` remained zero and
`iin_fb` remained near a negative offset (approximately -17,867). Battery
discharge averaged 3.76 A, while `ichg_fb` averaged approximately 3,777,034;
with no external load, these two readings were instead approximately 0.41 A
and 438,006. The feedback changed alongside total battery-side drain; these
readings do not establish an isolated USB measurement. After output was switched
off, drain returned near the router-only level and Mac USB input subsequently
resumed.

These observations do not establish an independent output-current sensor or
calibrate the raw IIO channels. Battery draw cannot distinguish router
consumption, converter losses and USB load on its own. Measured USB output
watts remain unavailable rather than substituting an unverified register or
the negotiated limit.

Primary references: [Silergy product identification](https://www.silergy.com/productsview/sy20798qeq),
[SY20798 register map, pages 25–34](https://www.silergy.com/download/downloadFile?ftype=note&id=5123&type=product).
The reserve controller uses router-only measurements rather than inventing an
output-current reading; see [USB reserve policy](usb-power-control.md).

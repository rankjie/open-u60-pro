# Wake recovery

The firmware remains responsible for cellular wake interrupts and the Auto Sleep
setting. The agent responds after Linux resumes; it cannot execute while the
system is suspended, and it does not enable unverified modem IRQs.

The implementation uses the firmware's `mode_power_on` event and a comparison of
`CLOCK_BOOTTIME` with `CLOCK_MONOTONIC`. A suspend interval advances only the first
clock. A long scheduling delay or wall-clock adjustment must not count as a wake.
Firmware wake events remain pending across a delayed or failed clock sample and
are cleared only after publishing recovery, so a consumed event is not lost.
One recovery owner publishes the resume event, reconnects signaling immediately,
asks the existing Wi-Fi owner to check and restore the saved uplink, and asks the
existing SMS collector to refresh its durable journal. Reconnecting
must preserve the current call and replay the existing event IDs.

An owned, timed kernel wakelock holds the system awake for a short recovery window
and is renewed while a managed call is in progress. Every renewal has a timeout,
so agent termination cannot leave an indefinite lock. The lock is released when
the recovery window and call end. Errors are reported with static codes; they do
not discard SMS or call journals or prevent a later recovery attempt.

Trusted server time is anchored to `CLOCK_BOOTTIME`, so command expiry continues
to advance during deep sleep without relying on the router's wall clock.

Validation covers clock/resume detection, bounded wake leases, stale-connection
replacement, durable SMS replay, and existing call lifecycle behavior. Hardware
checks can verify the timed lock without enabling Auto Sleep. Real cellular wake,
SMS arrival and an incoming call during sleep require an installed SIM and remain
separate acceptance checks.

The Rust suite passes 339 tests with four existing ignored tests, and the
AArch64 musl release is installed on the attached U60. The live upstream returned
to connected/online and signaling reconnected with the existing configuration.
The public identity endpoint responds through USB forwarding; protected calling
and SMS status endpoints continue to reject unauthenticated requests. These
checks do not simulate a cellular wake or establish call audio behavior.

The attached firmware already arms the modem remoteproc and SMP2P wake source.
This is capability evidence, not proof that an incoming SMS or voice call reaches
the wake path. No unverified GLINK IRQ setting is changed by this implementation.

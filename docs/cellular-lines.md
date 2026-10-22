# Cellular line attribution

The app owns one foreground SIM monitor and one observable `SIMState` per client,
shared across tabs through the existing LAN/P2P/relay transport. Calls renders
this state without starting requests or clearing it on entry. Concurrent SIM
reads share a request; the monitor reuses successful reads for 30 seconds, while
explicit settings reads remain live. Failed refreshes retain a confirmed line.
Loading, confirmed SIM unavailability, and read failure are distinct. Router or
SIM identity changes invalidate the current line and reject obsolete replies;
saved-number edits update it immediately. Foreground monitoring stops in the
background and resumes without discarding known state.

Incoming and outgoing call metadata also stores a `line` snapshot with
`iccid`, optional `number`, and `source` (`sim`, `manual`, or `unavailable`). The
snapshot is fixed when the call is created and retained in the call journal,
history, recording downloads, and iPhone cache. Changing the SIM or editing its
number cannot rewrite an existing call. Dial admission rechecks the captured SIM
before submitting ATD. Number metadata reflects the SIM or the user's saved
number; it is not caller-ID verification by the mobile operator.

The firmware SMS database contains no recipient-SIM number. The agent keeps
attribution in `/data/openu60-sms/lines.json`, using atomic private writes under
one mutex. A message identity includes its row ID, storage/date, payload hash,
and incoming/outgoing/draft category. Marking read leaves the identity intact;
deletion or reuse of an ID cannot transfer a previous message's line. This file
contains line metadata and hashes, not another copy of message text.
Attribution survives a row disappearing during a SIM swap and returning with the
same full message identity when that card is reinserted.

The existing SMS notification watcher captures lines before notification
delivery, with the same firmware events and timer. Newly observed incoming SMS
on a stable SIM receive its current line. Sending through the agent persists a
pending payload hash before the firmware side effect, confirms that the SIM
stayed the same, and associates the stored outgoing row with that captured line.
Pending attribution is bounded to five minutes. A successful send is not
reported failed merely because a later metadata write or reconciliation failed;
its already-persisted pending record allows the watcher to reconcile it.
An unavailable SIM-number read is logged and leaves attribution unknown; it
does not prevent an otherwise valid SMS send. Failure to persist the pending
record does prevent sending, before the firmware side effect.

Unproven attribution remains unknown: existing messages at first observation,
unobserved arrivals while the agent was stopped, SIM-transition batches, sends
outside the agent, and ambiguous identical pending sends across different SIMs.
Legacy calls/messages are never backfilled from whichever SIM is selected now.
History and Messages display the saved line for each entry, including after an
offline relaunch; read updates retain it. A SIM without a stored/manual number
still has its captured ICCID and is shown by its last four digits with Number
not set. Full ICCIDs remain in the record for identity matching.

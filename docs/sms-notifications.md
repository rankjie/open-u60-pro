# SMS arrival events

Both App push delivery and the configured SMS forwarder consume
`zwrt_wms_status_event` with `wms_status=new_sms_received` from the existing event
bus. The App collector persists new messages before waking the authenticated
server connection. Its 60-second reconciliation remains unchanged.

On the inspected MU5250 firmware, the native stored-message handler
`zte_wms_handler_mt_msg` writes the message and updates `sms_received_flag`, but
does not enqueue the native received-SMS pipe command. Another receive path does
enqueue it. The pipe's uloop callback publishes the event consumed by the agent.
This explains why messages reached the database while neither immediate push
nor event-triggered forwarding ran. The App collector eventually found them on
its minute interval. Baseline SMS notifications reached the server 34 and 59
seconds after their message timestamps; APNs accepted them within one second of
server receipt.

`tools/patch_wms_sms_events.py` prepares the firmware-specific correction. After
the normal stored-message flags are updated, it enqueues the existing native
received command, then resumes the original modem-storage cleanup. It uses the
native pipe because the ubus context belongs to the uloop thread, rather than the
modem command queue. Executable layout, instruction anchors and available code
padding must match the inspected build; other firmware is rejected.

The factory executable remains untouched. The patched copy is kept under
`/data/openu60-wms-event`, with the original retained as `factory`.
`scripts/openu60-wms-events.init` binds the copy and restarts the original service
once. Like the installed ADB and touchscreen services, it is invoked from the
firmware's existing `rc.local` path:

```sh
/etc/init.d/openu60-wms-events start >/tmp/openu60-wms-event.boot.log 2>&1 &
```

`scripts/install-wms-events-boot.sh` inserts the owned line before `exit 0`, with
the rest of this mixed startup file kept opaque and verified byte-for-byte before
replacement. A bounded startup
health check disables the patch, stops the
process, removes the bind mount and starts the factory service if startup fails
or repeated RPC checks fail. A changed factory executable is left in place for
inspection. Manual restoration uses:

```sh
/etc/init.d/openu60-wms-events rollback
```

On 2026-10-22, three real incoming test messages immediately produced the native
event; both enrolled phones' APNs requests were accepted 0–1 seconds after server
receipt, and the user confirmed timely notification delivery. Factory rollback
and reapplying the correction were also checked on the running router. The boot
entry is configured; a cold reboot was not required for these checks. The user's
Webhook remained disabled, so its external HTTP delivery was not retested.

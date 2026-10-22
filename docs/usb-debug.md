# Default USB debugging

On the inspected MU5250 firmware, setting `zwrt_bsp_usb.mode.mode=debug` does not
enable ADB after reboot. The vendor runtime API
`ubus call zwrt_bsp.usb set '{"mode":"debug"}'` does enable it.

`scripts/openu60-adb.init` waits up to 30 seconds
for the vendor USB service, requests debug mode, and checks the reported mode.
It changes no charging or powerbank setting. A failure returns nonzero with an
error on stderr; there is no retry loop after boot.

The inspected vendor firmware does not run a newly enabled OpenWrt init service.
The installer invokes it from the existing `rc.local` startup path instead,
preserving every original byte. Its boot result is logged to
`/tmp/openu60-adb.boot.log`.

Install through an existing ADB connection:

```sh
python3 tools/install-adb-boot.py
```

The service applies once per boot. A mode selected in the app remains in effect
until another change or reboot. Remove the installer-owned `openu60-adb start`
line from `rc.local` to disable the boot preference.

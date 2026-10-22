#!/bin/sh
set -eu
umask 077
staged_boot=''
restored_boot=''
trap 'test -z "$staged_boot" || rm -f "$staged_boot"; test -z "$restored_boot" || rm -f "$restored_boot"' EXIT
cp /tmp/openu60-wms-events.init /etc/init.d/openu60-wms-events.new
chmod 755 /etc/init.d/openu60-wms-events.new
mv /etc/init.d/openu60-wms-events.new /etc/init.d/openu60-wms-events
/etc/init.d/openu60-wms-events disable
target_boot=/etc/rc.local
entry='/etc/init.d/openu60-wms-events start >/tmp/openu60-wms-event.boot.log 2>&1 &'
count=$(grep -Fxc "$entry" "$target_boot" || true)
test "$count" -le 1
if test "$count" -eq 0; then
 test "$(grep -c '^exit 0$' "$target_boot")" = 1
 mode=$(stat -c '%a' "$target_boot")
 staged_boot=$(mktemp "$target_boot.openu60-wms.XXXXXX")
 restored_boot=$(mktemp "$target_boot.openu60-wms-recovered.XXXXXX")
 awk -v entry="$entry" '$0 == "exit 0" {print entry} {print}' "$target_boot" > "$staged_boot"
 awk -v entry="$entry" '$0 != entry {print}' "$staged_boot" > "$restored_boot"
 cmp -s "$target_boot" "$restored_boot"
 sh -n "$staged_boot" >/dev/null 2>&1
 chmod "$mode" "$staged_boot"
 mv "$staged_boot" "$target_boot"
 staged_boot=''
fi
sync
echo WMS_BOOT_ENTRY_INSTALLED

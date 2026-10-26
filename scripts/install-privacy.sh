#!/bin/sh
# Stops the firmware's vendor-cloud daemons and blocks their servers. Run on the router as root;
# safe to run again. See docs/privacy.md for what each item does and how to undo it.
set -eu

# Phone-home daemons. None may be a zte_topsw_daemon sync daemon: disabling one of those
# stalls boot (see CLAUDE.md), so the script refuses instead.
DAEMONS='zte_smart_manage zte_topsw_get_brand scp_agent zte_topsw_tr069_sub'
HOSTS='rot-dispatch-eu.ztesmarthome.com rot-dispatch-link.ztehome.com.cn rot-dispatch-fmc-test2.zx.zte.com.cn api-data.nubia.com api-data-test.nubia.com'
SYNC=/etc/config/zte_topsw_daemon.conf
BEGIN='# openu60-privacy begin'
END='# openu60-privacy end'

for name in $DAEMONS; do
  if grep -Eq "^[[:space:]]*sync[[:space:]]+[^[:space:]]+[[:space:]]+$name[[:space:]]*\$" "$SYNC"; then
    echo "REFUSED: $name is a boot sync daemon" >&2; exit 1
  fi
done
for name in $DAEMONS; do
  test -x "/etc/init.d/$name" || { echo "MISSING: /etc/init.d/$name" >&2; exit 1; }
  "/etc/init.d/$name" stop >/dev/null 2>&1 || true
  "/etc/init.d/$name" disable
  if pidof "$name" >/dev/null; then kill $(pidof "$name"); fi
done

# Replaces this script's block in a file, leaving everything else untouched.
put_block() {
  file=$1 body=$2
  staged=$(mktemp "$file.openu60.XXXXXX")
  awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1} !skip {print} $0 == e {skip=0}' "$file" > "$staged"
  printf '%s\n%s%s\n' "$BEGIN" "$body" "$END" >> "$staged"
  chmod "$(stat -c '%a' "$file")" "$staged"
  mv "$staged" "$file"
}

entries=''
for host in $HOSTS; do entries="${entries}0.0.0.0 $host
:: $host
"; done
put_block /etc/hosts "$entries"

# Every vendor cloud connection observed used TCP 30443; nothing of ours does. OUTPUT only
# covers the router's own traffic, not devices behind it.
rules='for ipt in iptables ip6tables; do
  $ipt -C OUTPUT -p tcp --dport 30443 -j REJECT 2>/dev/null || $ipt -I OUTPUT -p tcp --dport 30443 -j REJECT
done
'
put_block /etc/firewall.user "$rules"
sh -c "$rules"

killall -HUP dnsmasq 2>/dev/null || true
# zte_smart_manage's per-device app usage history (deep packet inspection results).
rm -f /ai_data/config/smart_manage_record.db /tmp/smart_manage_record.db
sync
echo PRIVACY_INSTALLED

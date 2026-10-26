# Vendor phone-home removal

The stock firmware (`STD_PL_MU5250V1.0.0B02`) keeps the router in contact with ZTE's cloud
even when idle. A 15-minute capture of the router's own traffic (DNS lookups, new conntrack
flows and socket owners, LAN clients excluded) on 2026-10-26 found:

| Process | Destination | What it does |
|---|---|---|
| `zte_smart_manage` | `rot-dispatch-eu.ztesmarthome.com:30443` (AWS Frankfurt) | Deep packet inspection of LAN traffic (`xdpi_support=1`); keeps a per-device (MAC, hostname) timeline of app use (ChatGPT, YouTube, Twitter, …) in `/ai_data/config/smart_manage_record.db`; ZTE Home app link (`rot-dispatch-link.ztehome.com.cn`) |
| `zte_topsw_get_brand` | same host, port 30443 | Looks up the brand of each LAN client (`get_client_brand=1`), i.e. sends the client list to ZTE |
| `scp_agent` | `rot-dispatch-eu.ztesmarthome.com:30443` | ZTE smart-home remote management over MQTT (`support_remote=2`) |
| `zte_topsw_tr069_sub` | none (CWMP disabled) | TR-069 client; idle but unnecessary |

Both persistent TLS sessions reconnected every few minutes. Also inspected and left alone:
`zte_dm` (firmware update; a boot sync daemon, polling already off), the `dadian` analytics
configuration (`api-data.nubia.com`; no binary on this firmware reads it or contains the
upload host), `zte_topsw_mdm` and `kpi_gen` (local only), NTP, and the GNSS assistance
configuration (injection off).

Ours: PandaFan reaches its API (`www.apidarouter.com`), and the Wi-Fi uplink checks
`http://www.apple.com/library/test/success.html` every 10 minutes while online (every
30 seconds while offline or behind a portal).

## What `scripts/install-privacy.sh` does

Run on the router as root (`adb push` then `sh`); it is idempotent.

1. Refuses if any target is listed as a sync daemon in `/etc/config/zte_topsw_daemon.conf`,
   then stops and `init.d disable`s `zte_smart_manage`, `zte_topsw_get_brand`, `scp_agent`
   and `zte_topsw_tr069_sub`.
2. Adds a marked block to `/etc/hosts` resolving the ZTE cloud and analytics hosts to
   `0.0.0.0`/`::`. The router's own resolver and dnsmasq (LAN clients) both read it.
3. Adds a marked block to `/etc/firewall.user` rejecting the router's own outgoing TCP 30443
   (IPv4 and IPv6), which every observed vendor connection used.
4. Deletes the recorded app-use history.

Verified after a reboot: boot sync reports success, the four daemons stay stopped, the
firewall rules are reloaded, and the Wi-Fi uplink, hotspot, touchscreen, agent and PandaFan
come back.

## Undo

```sh
for n in zte_smart_manage zte_topsw_get_brand scp_agent zte_topsw_tr069_sub; do
  /etc/init.d/$n enable; /etc/init.d/$n start
done
# then delete the "# openu60-privacy" blocks from /etc/hosts and /etc/firewall.user
```

The pre-install copies of `/etc/hosts` and `/etc/firewall.user` are in
`/data/openu60-privacy-backup/`.

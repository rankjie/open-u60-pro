mod at_cmd;
mod at_terminal;
mod auth;
mod bearer;
mod cache;
mod cell;
mod charge_policy;
mod conn_watchdog;
mod device_ext;
pub mod doh;
mod esim;
mod esim_download;
mod esim_native;
mod event_bus;
mod handlers;
mod lan_test;
mod live_activity;
mod management;
mod modem_ext;
mod network_ext;
mod oos_policy;
mod power;
mod powerbank_reserve;
mod qrtr_uim;
mod router;
mod remote_calling;
mod scheduler;
mod server;
mod sim;
mod cellular_line;
mod sim_identity;
mod sms;
mod sms_history;
mod sms_forward;
mod sms_notifications;
mod speedtest;
mod stk;
mod system;
mod tailscale;
mod telephony;
mod ubus;
mod usb;
mod wifi;
mod wifi_uplink;
mod wifi_time;

use std::sync::Arc;

use event_bus::EventBus;
use handlers::AppState;

const DEFAULT_BIND: &str = "0.0.0.0:9090";
// 4 workers: tailscale setup/logout are legitimately slow (up to ~1-2 min
// against the control plane) and must not starve the rest of the API.
const DEFAULT_THREADS: usize = 4;

fn main() {
    // Diagnostics: `zte-agent esim-native chip info` runs one native eSIM command and exits.
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("wifi-status") {
        if let Err(error) = wifi_uplink::ui_status_cli() { eprintln!("{error}"); std::process::exit(1); }
        return;
    }
    if args.get(1).map(String::as_str) == Some("esim-native") {
        std::process::exit(esim_native::cli(&args[2..]));
    }

    let bind = std::env::var("ZTE_AGENT_BIND").unwrap_or_else(|_| DEFAULT_BIND.to_string());
    let threads: usize = std::env::var("ZTE_AGENT_THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_THREADS);

    let state = Arc::new(AppState::new());

    // Set password from environment if provided
    if let Ok(pw) = std::env::var("ZTE_AGENT_PASSWORD") {
        state.auth.set_password(&pw);
    }

    // Event bus: single `ubus listen` process dispatches to subscribers
    let event_bus = Arc::new(EventBus::new());
    let sms_rx = event_bus.subscribe("zwrt_wms_status_event");
    let sms_notification_rx = event_bus.subscribe_many(&["zwrt_wms_status_event", power::RESUMED, sim_identity::EVENT]);
    let charger_rx = event_bus.subscribe("BSP_CHARGER_EVENT");
    let service_rx = event_bus.subscribe("zwrt_servicestatus");
    let wan_status_rx = event_bus.subscribe("router_event_wan_connect_status");
    let ts_wan_rx = event_bus.subscribe("router_event_wan_connect_status");
    let apns_events = [
        "zwrt_card_state_event",
        "router_event_wan_connect_status",
        "network.interface",
        sim_identity::EVENT,
    ]
    .into_iter()
    .map(|name| (name, event_bus.subscribe(name)))
    .collect();
    let cache_events = cache::EVENTS
        .iter()
        .map(|&name| (name, event_bus.subscribe(name)))
        .collect();
    let oos_service_rx = event_bus.subscribe("zwrt_servicestatus");
    let connwd_wan_rx = event_bus.subscribe("router_event_wan_connect_status");
    // Both the firmware event and a detected suspend wake the same Wi-Fi owner.
    let power_rx = event_bus.subscribe(power::RESUMED);
    let recovery_rx = event_bus.subscribe("zwrt_device_power_state_event");
    let reserve_rx = event_bus.subscribe_many(&["BSP_POWERBANK_EVENT", "BSP_CHARGER_EVENT",
        power::RESUMED, powerbank_reserve::CHANGED]);
    let wake_recovery = Arc::new(power::Recovery::new());
    let identity_events = sim_identity::FIRMWARE_EVENTS
        .iter()
        .map(|&name| (name, event_bus.subscribe(name)))
        .collect();
    event_bus.start();
    wake_recovery.start(recovery_rx, Arc::clone(&event_bus));
    state.powerbank_reserve.start(Arc::clone(&event_bus), reserve_rx, Arc::clone(&state.cache));
    let wake_wifi = state.wifi_uplink.clone();
    system::spawn_named("wifi-power-watch", move || {
        for event in power_rx.iter() {
            if event["resumed"] == true {
                system::arm_post_wifi_watchdog(std::time::Duration::from_secs(150));
                if let Err(error) = wake_wifi.resume() { eprintln!("[wifi-uplink] {error}"); }
            }
        }
    });

    Arc::clone(&state.cache).start_event_invalidation(cache_events);
    state.sim_identity.start(Arc::clone(&event_bus), Arc::clone(&state.cache), identity_events);

    state.live_activity.start(Arc::clone(&state), apns_events);
    state.remote_calling.start(Arc::clone(&state), Arc::clone(&wake_recovery));
    state.sms_notifications.start(sms_notification_rx, wake_recovery, Arc::clone(&state));
    state.doh.auto_start();
    state.wifi_uplink.attach_connection(state.remote_calling.clone());
    state.wifi_uplink.start();
    state.scheduler.start(Arc::clone(&state));
    state
        .charge_limit
        .start(charger_rx, Arc::clone(&state.cache));
    state.sms_forward.start(sms_rx, service_rx, wan_status_rx);
    state.tailscale.auto_start();
    state.tailscale.start_wan_watch(ts_wan_rx);
    state.oos_policy.start(
        Box::new(oos_policy::DeviceEffects::new(Arc::clone(&state))),
        busy_check(&state),
        oos_service_rx,
    );
    state.conn_watchdog.start(
        Box::new(conn_watchdog::DeviceEffects::new(Arc::clone(&state))),
        busy_check(&state),
        connwd_wan_rx,
    );

    // Firmware bug guard: zte_post_wifi.sh can spin forever after any Wi-Fi
    // reconfiguration (see system::kill_stuck_post_wifi); sweep every 5 min.
    system::start_post_wifi_watchdog();

    server::start(&bind, threads, state);
}

/// Guard shared by the no-service policy and the connectivity watchdog: the
/// reason an action must wait, or `None`. Only called when a policy is about
/// to act (a few times per incident), so it can afford an `AT+CLCC` to
/// confirm a call flag the app may never have cleared.
fn busy_check(state: &Arc<AppState>) -> Box<dyn Fn() -> Option<&'static str> + Send> {
    let state = Arc::clone(state);
    Box::new(move || {
        use std::sync::atomic::Ordering;
        if state.speedtest.is_running() {
            return Some("speed test");
        }
        // The WAN is down for up to a minute while the modem attaches with a new profile.
        if state.esim.recently_switched() {
            return Some("eSIM profile switch");
        }
        // USSD prompts expire network-side within a few minutes; treat the
        // flag as stale after 3 min.
        let ussd_at = state.ussd_prompt_at.load(Ordering::Relaxed);
        if ussd_at != 0 && conn_watchdog::unix_now().saturating_sub(ussd_at) < 180 {
            return Some("USSD session");
        }
        if state.call_active.load(Ordering::Relaxed) {
            // Re-check with the modem: the far end may have hung up after
            // the app stopped polling call_status. Fail closed: only a
            // complete "no calls" reply clears the flag; an empty, partial
            // or ERROR reply keeps deferring (the policies retry in 60 s).
            match at_cmd::send(&state.at_port, "AT+CLCC", 2) {
                Ok(resp) if clcc_confirms_idle(&resp) => {
                    state.call_active.store(false, Ordering::Relaxed)
                }
                Ok(resp) => {
                    eprintln!(
                        "[busy_check] AT+CLCC inconclusive ({} bytes), keeping call_active",
                        resp.len()
                    );
                    return Some("voice call");
                }
                Err(e) => {
                    eprintln!("[busy_check] AT+CLCC failed: {e}; keeping call_active");
                    return Some("voice call");
                }
            }
        }
        None
    })
}

/// Whether an `AT+CLCC` reply positively confirms no call is in progress: it
/// must carry the final `OK` and list no `+CLCC:` entries. Anything else
/// (empty, truncated, `ERROR`) is inconclusive and must not clear the flag.
fn clcc_confirms_idle(resp: &str) -> bool {
    resp.contains("OK") && telephony::parse_clcc(resp).is_empty()
}

#[cfg(test)]
mod tests {
    use super::clcc_confirms_idle;

    #[test]
    fn clcc_idle_only_on_final_ok_without_calls() {
        assert!(clcc_confirms_idle("\r\nOK\r\n"));
        assert!(clcc_confirms_idle("AT+CLCC\r\r\nOK\r\n"));
    }

    #[test]
    fn clcc_inconclusive_replies_keep_call_active() {
        assert!(!clcc_confirms_idle(""));
        assert!(!clcc_confirms_idle("\r\nERROR\r\n"));
        assert!(!clcc_confirms_idle("+CME ERROR: 3\r\n"));
        // Command echo only: the reader timed out before any reply packet.
        assert!(!clcc_confirms_idle("AT+CLCC\r\n"));
    }

    #[test]
    fn clcc_with_call_listed_is_not_idle() {
        assert!(!clcc_confirms_idle(
            "+CLCC: 1,0,0,0,0,\"+15551234567\",145\r\nOK\r\n"
        ));
        // Truncated: call line captured but the final OK went to another reader.
        assert!(!clcc_confirms_idle("+CLCC: 1,1,4,0,0,\"123\",129\r\n"));
    }
}

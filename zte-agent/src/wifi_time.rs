use std::net::{Ipv4Addr, UdpSocket};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const NTP_EPOCH: u64 = 2_208_988_800;

pub fn addresses(output: &str) -> Result<Vec<Ipv4Addr>, &'static str> {
    let mut answer = false;
    let mut addresses = Vec::new();
    for line in output.lines() {
        if line.trim_start().starts_with("Name:") {
            answer = true;
        }
        if answer && line.trim_start().starts_with("Address:") {
            if let Some(address) = line.split_whitespace().nth(1).and_then(|s| s.parse().ok()) {
                if !addresses.contains(&address) {
                    addresses.push(address);
                }
            }
        }
    }
    if addresses.is_empty() {
        return Err("The configured time server has no IPv4 address");
    }
    Ok(addresses)
}

pub fn query(address: Ipv4Addr) -> Result<SystemTime, &'static str> {
    let socket =
        UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|_| "Cannot open the time client")?;
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "Cannot set the time client deadline")?;
    socket
        .set_write_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "Cannot set the time client deadline")?;
    socket
        .connect((address, 123))
        .map_err(|_| "Cannot reach the configured time server")?;
    let mut request = [0u8; 48];
    request[0] = 0x23;
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Device clock predates the Unix epoch")?
        .as_secs();
    request[40..44].copy_from_slice(&((seconds + NTP_EPOCH) as u32).to_be_bytes());
    request[44..48].copy_from_slice(&uuid::Uuid::new_v4().as_bytes()[..4]);
    let started = Instant::now();
    if socket
        .send(&request)
        .map_err(|_| "Cannot request network time")?
        != request.len()
    {
        return Err("Incomplete network time request");
    }
    let mut reply = [0u8; 512];
    let length = socket
        .recv(&mut reply)
        .map_err(|_| "The configured time server did not reply within 3 seconds")?;
    let timestamp = response(&reply[..length], &request[40..48])?;
    Ok(timestamp + started.elapsed() / 2)
}

fn response(reply: &[u8], origin: &[u8]) -> Result<SystemTime, &'static str> {
    // RFC 5905: accept synchronized unicast replies tied to this exact request.
    if reply.len() < 48
        || reply[0] >> 6 == 3
        || !matches!((reply[0] >> 3) & 7, 3 | 4)
        || reply[0] & 7 != 4
        || !(1..=15).contains(&reply[1])
        || &reply[24..32] != origin
        || reply[40..48] == [0; 8]
    {
        return Err("The time server returned an invalid or unsynchronized reply");
    }
    let seconds = u32::from_be_bytes(reply[40..44].try_into().unwrap()) as u64;
    let era = if seconds < NTP_EPOCH { 1u64 << 32 } else { 0 };
    let fraction = u32::from_be_bytes(reply[44..48].try_into().unwrap()) as u64;
    Ok(UNIX_EPOCH
        + Duration::new(
            seconds + era - NTP_EPOCH,
            ((fraction * 1_000_000_000) >> 32) as u32,
        ))
}

#[cfg(target_os = "linux")]
pub fn set_utc(time: SystemTime) -> Result<(), &'static str> {
    let time = time
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Network time predates the Unix epoch")?;
    let value = libc::timespec {
        tv_sec: time
            .as_secs()
            .try_into()
            .map_err(|_| "Network time exceeds the system clock range")?,
        tv_nsec: time.subsec_nanos() as libc::c_long,
    };
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &value) } != 0 {
        return Err("Cannot set the router UTC clock");
    }
    Ok(())
}
#[cfg(not(target_os = "linux"))]
pub fn set_utc(_: SystemTime) -> Result<(), &'static str> {
    Err("Router time changes require Linux")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn reply(seconds: u64) -> [u8; 48] {
        let mut packet = [0u8; 48];
        packet[0] = 0x24;
        packet[1] = 2;
        packet[24..32].copy_from_slice(b"syntheti");
        packet[40..44].copy_from_slice(&((seconds + NTP_EPOCH) as u32).to_be_bytes());
        packet[44..48].copy_from_slice(&(1u32 << 31).to_be_bytes());
        packet
    }
    #[test]
    fn utc_timestamp_and_2036_rollover_are_decoded_without_timezone_bias() {
        for seconds in [1_792_583_000, 2_200_000_000] {
            let time = response(&reply(seconds), b"syntheti")
                .unwrap()
                .duration_since(UNIX_EPOCH)
                .unwrap();
            assert_eq!(time, Duration::new(seconds, 500_000_000));
        }
    }
    #[test]
    fn mismatched_unsynchronized_and_kiss_of_death_replies_are_rejected() {
        let good = reply(1_792_583_000);
        assert!(response(&good, b"different").is_err());
        assert!(response(&good[..47], b"syntheti").is_err());
        for (index, value) in [(0, 0xe4), (0, 0x23), (0, 0x04), (1, 0), (1, 16)] {
            let mut invalid = good;
            invalid[index] = value;
            assert!(response(&invalid, b"syntheti").is_err());
        }
        let mut zero = good;
        zero[40..48].fill(0);
        assert!(response(&zero, b"syntheti").is_err());
    }
    #[test]
    fn dns_server_address_is_never_used_as_the_ntp_answer() {
        let output = "Server: 192.0.2.1\nAddress: 192.0.2.1:53\nName: time.example\nAddress: 198.51.100.5\nAddress: 2001:db8::5\nAddress: 198.51.100.6\n";
        assert_eq!(
            addresses(output).unwrap(),
            vec![
                "198.51.100.5".parse::<Ipv4Addr>().unwrap(),
                "198.51.100.6".parse().unwrap()
            ]
        );
        assert!(addresses("Server: 192.0.2.1\nAddress: 192.0.2.1\n").is_err());
    }
}

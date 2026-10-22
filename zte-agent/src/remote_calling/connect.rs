use super::storage::{private_read, private_write};
use base64::Engine;
use hpke::{aead::AesGcm256, kdf::HkdfSha256, kem::DhP256HkdfSha256, Deserializable, Kem, OpModeR, Serializable};
use p256::elliptic_curve::zeroize::{Zeroize, Zeroizing};
use serde::Deserialize;
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;

type PrivateKey = <DhP256HkdfSha256 as Kem>::PrivateKey;
pub struct Identity {
    private: PrivateKey,
    public: String,
    attempts: Mutex<Vec<Instant>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Identity, Value) {
        // Public synthetic material emitted by the native CryptoKit interoperability test.
        let value: Value = serde_json::from_str(include_str!("fixtures/device-connect-hpke.synthetic.json")).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD.decode(value["syntheticPrivateKey"].as_str().unwrap()).unwrap();
        let private = PrivateKey::from_bytes(&bytes).unwrap();
        let public = base64::engine::general_purpose::STANDARD.encode(DhP256HkdfSha256::sk_to_pk(&private).to_bytes());
        (Identity { private, public, attempts: Mutex::new(Vec::new()) }, value)
    }
    #[test]
    fn cryptokit_password_envelope_binds_router_request_phone_and_expiry() {
        let (identity, value) = fixture();
        let router = Uuid::parse_str(value["routerId"].as_str().unwrap()).unwrap();
        let now = value["serverTime"].as_u64().unwrap();
        assert_eq!(identity.authorize(&value, router, now, |p|p == value["syntheticPassword"].as_str().unwrap()), Ok(true));
        assert_eq!(identity.authorize(&value, router, now, |_|false), Ok(false));
        for field in ["phoneToken", "requestId", "ciphertext"] {
            let (identity, mut altered) = fixture();
            altered[field] = match field {
                "phoneToken" => Value::String("z".repeat(43)),
                "requestId" => json_uuid(),
                _ => {
                    let mut data = base64::engine::general_purpose::STANDARD.decode(altered[field].as_str().unwrap()).unwrap();
                    data[0] ^= 1;
                    Value::String(base64::engine::general_purpose::STANDARD.encode(data))
                },
            };
            assert!(identity.authorize(&altered, router, now, |_|panic!("Tampered envelope reached password verification")).is_err());
        }
        let (identity, value) = fixture();
        assert_eq!(identity.authorize(&value, router, now + 61, |_|panic!("Expired login accepted")), Err("connection_login_expired"));
        assert!(identity.authorize(&value, Uuid::new_v4(), now, |_|panic!("Wrong router accepted")).is_err());
    }
    fn json_uuid() -> Value { Value::String(Uuid::new_v4().to_string()) }
    #[test]
    fn password_attempts_are_bounded_and_identity_survives_process_restart() {
        let (identity, value) = fixture();
        let router = Uuid::parse_str(value["routerId"].as_str().unwrap()).unwrap();
        for _ in 0..6 { assert_eq!(identity.authorize(&value, router, 1_800_000_000, |_|true), Ok(true)); }
        assert_eq!(identity.authorize(&value, router, 1_800_000_000, |_|panic!("Rate limit bypassed")), Err("connection_rate_limited"));
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!("openu60-synthetic-identity-{}", Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join("identity.private");
        let first = Identity::at(&path).unwrap();
        assert_eq!(first.public_key(), Identity::at(&path).unwrap().public_key());
        std::fs::write(&path, b"invalid synthetic key").unwrap();
        assert!(matches!(Identity::at(&path), Err("invalid_connection_identity")));
        std::fs::remove_dir_all(directory).unwrap();
    }
}
impl Identity {
    pub fn load() -> Result<Self, &'static str> { Self::at(Path::new("/data/openu60-connect/identity.private")) }
    fn at(path: &Path) -> Result<Self, &'static str> {
        let private = match std::fs::symlink_metadata(path) {
            Ok(_) => {
                let bytes = Zeroizing::new(private_read(path).map_err(|_| "connection_identity_read_failed")?);
                PrivateKey::from_bytes(&bytes).map_err(|_| "invalid_connection_identity")?
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                use std::io::Read;
                let mut seed = Zeroizing::new([0u8; 32]);
                std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut *seed)).map_err(|_| "connection_random_failed")?;
                let (private, _) = DhP256HkdfSha256::derive_keypair(&*seed);
                let staged = path.with_file_name(format!(".identity-create-{}", Uuid::new_v4()));
                private_write(&staged, &private.to_bytes()).map_err(|_| "connection_identity_write_failed")?;
                // Publish once: concurrent startup cannot rotate an existing identity.
                let linked = std::fs::hard_link(&staged, path);
                std::fs::remove_file(&staged).map_err(|_| "connection_identity_cleanup_failed")?;
                match linked {
                    Ok(()) => {
                        std::fs::File::open(path.parent().ok_or("invalid_connection_identity_path")?)
                            .and_then(|directory|directory.sync_all()).map_err(|_| "connection_identity_sync_failed")?;
                        private
                    },
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                        let bytes = Zeroizing::new(private_read(path).map_err(|_| "connection_identity_read_failed")?);
                        PrivateKey::from_bytes(&bytes).map_err(|_| "invalid_connection_identity")?
                    },
                    Err(_) => return Err("connection_identity_write_failed"),
                }
            },
            Err(_) => return Err("connection_identity_read_failed"),
        };
        let public = base64::engine::general_purpose::STANDARD.encode(DhP256HkdfSha256::sk_to_pk(&private).to_bytes());
        Ok(Self { private, public, attempts: Mutex::new(Vec::new()) })
    }
    pub fn public_key(&self) -> &str { &self.public }
    pub fn authorize(&self, request: &Value, router: Uuid, now: u64, verify: impl FnOnce(&str) -> bool) -> Result<bool, &'static str> {
        {
            let mut attempts = self.attempts.lock().unwrap();
            attempts.retain(|time| time.elapsed() < Duration::from_secs(60));
            if attempts.len() >= 6 { return Err("connection_rate_limited"); }
            attempts.push(Instant::now());
        }
        let id = request["requestId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_connection_id")?;
        if request["routerId"].as_str().and_then(|v|Uuid::parse_str(v).ok()) != Some(router) { return Err("invalid_connection_router"); }
        let token = request["phoneToken"].as_str().filter(|v|v.len() == 43 && v.bytes().all(|b|b.is_ascii_alphanumeric() || b"_-".contains(&b))).ok_or("invalid_connection_token")?;
        let decode = |key: &str, min: usize, max: usize| -> Result<Vec<u8>, &'static str> {
            let encoded = request[key].as_str().filter(|v| v.len() <= (max + 2) / 3 * 4).ok_or("invalid_connection_envelope")?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_| "invalid_connection_envelope")?;
            if bytes.len() < min || bytes.len() > max { return Err("invalid_connection_envelope"); }
            Ok(bytes)
        };
        let enc = <DhP256HkdfSha256 as Kem>::EncappedKey::from_bytes(&decode("enc", 65, 65)?).map_err(|_| "invalid_connection_key")?;
        let mut receiver = hpke::setup_receiver::<AesGcm256, HkdfSha256, DhP256HkdfSha256>(&OpModeR::Base,
            &self.private, &enc, b"OpenU60 device connect v1").map_err(|_| "invalid_connection_envelope")?;
        let aad = format!("OpenU60 connect v1\n{router}\n{id}\n{token}");
        let plaintext = Zeroizing::new(receiver.open(&decode("ciphertext", 32, 2048)?, aad.as_bytes()).map_err(|_| "invalid_connection_envelope")?);
        #[derive(Deserialize)]
        #[serde(rename_all="camelCase", deny_unknown_fields)]
        struct Login { password: String, expires_at: u64 }
        impl Drop for Login { fn drop(&mut self) { self.password.zeroize(); } }
        let login: Login = serde_json::from_slice(&plaintext).map_err(|_| "invalid_connection_login")?;
        if login.password.is_empty() || login.password.len() > 256 || login.expires_at <= now || login.expires_at > now + 90 { return Err("connection_login_expired"); }
        Ok(verify(&login.password))
    }
}

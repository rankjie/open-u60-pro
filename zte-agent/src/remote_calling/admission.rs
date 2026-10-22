use super::journal::Command;
use base64::Engine;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn verify(token: &str, phone: Uuid, command: &Command, proof: &Value) -> Result<(), &'static str> {
    command.validate()?;
    if command.phone.as_ref().is_some_and(|device| device.id != phone) { return Err("invalid_call_admission"); }
    if proof["phoneId"].as_str().and_then(|v|Uuid::parse_str(v).ok()) != Some(phone) { return Err("invalid_call_admission"); }
    let signature = proof["mac"].as_str().filter(|v|v.len() == 43).ok_or("invalid_call_admission")?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(signature).map_err(|_| "invalid_call_admission")?;
    let mut message = format!("OpenU60 call admission v1\0{phone}\0{}\0{}\0{}\0{}\0{}\0{}",
        command.request_id, command.call_id, command.action, command.expires_at,
        command.number.as_deref().unwrap_or(""), command.digits.as_deref().unwrap_or(""));
    if let Some(device) = &command.phone { message.push_str(&format!("\0{}\0{}\0{}", device.id, device.name, device.model)); }
    let key = Sha256::digest(token.as_bytes());
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).map_err(|_| "invalid_call_admission")?;
    mac.update(message.as_bytes());
    mac.verify_slice(&bytes).map_err(|_| "invalid_call_admission")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn server_admission_authenticates_the_phone_and_every_effect_field() {
        let phone = Uuid::parse_str("00000000-0000-4000-8000-000000000001").unwrap();
        let token = "r".repeat(43);
        let value = json!({"type":"command","requestId":"00000000-0000-4000-8000-000000000002",
            "callId":"00000000-0000-4000-8000-000000000003","action":"dial","number":"+12345","expiresAt":1800000020});
        let command: Command = serde_json::from_value(value.clone()).unwrap();
        let proof = json!({"phoneId":phone,"mac":"xjR1rpmlcyFjmmTUQyYGOPu_5XgMkvh9WnwhGGuv-co"});
        assert_eq!(verify(&token, phone, &command, &proof), Ok(()));
        assert!(verify(&token, Uuid::new_v4(), &command, &proof).is_err());
        assert!(verify(&"z".repeat(43), phone, &command, &proof).is_err());
        assert!(verify(&token, phone, &command, &Value::Null).is_err());
        for (field, replacement) in [("requestId",json!(Uuid::new_v4())),("callId",json!(Uuid::new_v4())),
            ("action",json!("answer")),("expiresAt",json!(1800000030)),("number",json!("+54321")),("digits",json!("1"))] {
            let mut changed = value.clone(); changed[field] = replacement;
            let changed: Command = serde_json::from_value(changed).unwrap();
            assert!(verify(&token, phone, &changed, &proof).is_err(), "Changed {field} admitted");
        }
    }
    #[test]
    fn device_attribution_is_bound_to_the_admitted_phone_and_metadata() {
        let phone = Uuid::parse_str("00000000-0000-4000-8000-000000000001").unwrap();
        let value = json!({"type":"command","requestId":"00000000-0000-4000-8000-000000000002",
            "callId":"00000000-0000-4000-8000-000000000003","action":"dial","number":"+12345","expiresAt":1800000020,
            "phone":{"id":phone,"name":"iPhone 16 Pro","model":"iPhone17,1"}});
        let command: Command = serde_json::from_value(value.clone()).unwrap();
        let proof = json!({"phoneId":phone,"mac":"6uVy_6NTB9OdC8qz2FvHFLjNLYdWWeGWRKbdjQpi3Qk"});
        assert_eq!(verify(&"r".repeat(43), phone, &command, &proof), Ok(()));
        for (field, replacement) in [("id",json!(Uuid::new_v4())),("name",json!("iPhone 17 Pro")),("model",json!("iPhone18,1"))] {
            let mut changed = value.clone(); changed["phone"][field] = replacement;
            let changed: Command = serde_json::from_value(changed).unwrap();
            assert!(verify(&"r".repeat(43), phone, &changed, &proof).is_err());
        }
    }
}

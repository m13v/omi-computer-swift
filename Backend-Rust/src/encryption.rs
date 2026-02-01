// Encryption utilities - Port from Python backend utils/encryption.py
// Used to decrypt user data with enhanced protection level (AES-256-GCM)

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use hkdf::Hkdf;
use sha2::Sha256;

/// Derives a user-specific 32-byte key from the master secret and user ID (salt).
/// Matches Python: HKDF(SHA256, length=32, salt=uid, info=b'user-data-encryption')
fn derive_key(master_secret: &[u8], uid: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(uid.as_bytes()), master_secret);
    let mut key = [0u8; 32];
    hk.expand(b"user-data-encryption", &mut key)
        .expect("32 bytes is a valid length for HKDF");
    key
}

/// Decrypts a base64 encoded string using a user-specific key.
/// Format: base64(12-byte nonce + ciphertext + auth tag)
/// Returns the decrypted string, or the original on failure.
pub fn decrypt(encrypted_data: &str, uid: &str, master_secret: &[u8]) -> String {
    if encrypted_data.is_empty() {
        return encrypted_data.to_string();
    }

    // Decode base64
    let encrypted_payload = match BASE64.decode(encrypted_data) {
        Ok(payload) => payload,
        Err(_) => {
            // Not valid base64, likely not encrypted
            return encrypted_data.to_string();
        }
    };

    // Need at least 12 bytes nonce + 16 bytes auth tag
    if encrypted_payload.len() < 28 {
        return encrypted_data.to_string();
    }

    // Extract nonce (first 12 bytes) and ciphertext (rest)
    let (nonce_bytes, ciphertext) = encrypted_payload.split_at(12);

    // Derive key
    let key = derive_key(master_secret, uid);

    // Decrypt
    let cipher = Aes256Gcm::new_from_slice(&key).expect("Key is 32 bytes");
    let nonce = Nonce::from_slice(nonce_bytes);

    match cipher.decrypt(nonce, ciphertext) {
        Ok(plaintext) => match String::from_utf8(plaintext) {
            Ok(s) => s,
            Err(_) => encrypted_data.to_string(),
        },
        Err(e) => {
            tracing::debug!(
                "Decryption failed for user {}: {:?}. Returning original.",
                uid,
                e
            );
            encrypted_data.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decrypt_returns_original_on_invalid_base64() {
        let result = decrypt("not valid base64!!!", "test-uid", b"testsecret12345678901234567890123");
        assert_eq!(result, "not valid base64!!!");
    }

    #[test]
    fn test_decrypt_returns_original_on_empty_string() {
        let result = decrypt("", "test-uid", b"testsecret12345678901234567890123");
        assert_eq!(result, "");
    }

    #[test]
    fn test_decrypt_returns_original_on_short_payload() {
        // Valid base64 but too short to be encrypted data
        let result = decrypt("SGVsbG8=", "test-uid", b"testsecret12345678901234567890123");
        assert_eq!(result, "SGVsbG8="); // "Hello" in base64, but too short
    }
}

//! 8-character lowercase alphanumeric session id.

use rand::RngExt as _;
use thiserror::Error;

pub const SESSION_ID_LEN: usize = 8;
const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";

#[derive(Debug, Error)]
pub enum IdError {
    #[error("session id must be {SESSION_ID_LEN} lowercase alphanumeric characters: {0:?}")]
    Invalid(String),
}

/// Generate a fresh 8-character lowercase alphanumeric session id.
///
/// Drawn from a 36-character alphabet (`0-9a-z`). Uses the thread-local
/// CSPRNG so values are not predictable across processes. At 36^8 ≈ 2.8 ×
/// 10^12 keys the birthday bound reaches ~50 % at roughly 1.7 million
/// concurrent ids — plenty of headroom for the sessions namespace.
#[must_use]
pub fn new_session_id() -> String {
    let mut rng = rand::rng();
    (0..SESSION_ID_LEN)
        .map(|_| {
            let idx = rng.random_range(0..ALPHABET.len());
            ALPHABET[idx] as char
        })
        .collect()
}

/// # Errors
/// Returns `IdError::Invalid` when the id is not exactly 8 lowercase alphanumeric characters.
pub fn validate(id: &str) -> Result<(), IdError> {
    if id.len() != SESSION_ID_LEN {
        return Err(IdError::Invalid(id.to_string()));
    }
    if !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        return Err(IdError::Invalid(id.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests;

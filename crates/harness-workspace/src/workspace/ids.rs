//! UUID-backed harness session ids.

use thiserror::Error;
use uuid::Uuid;

pub const SESSION_ID_LEN: usize = 36;

#[derive(Debug, Error)]
pub enum IdError {
    #[error("session id must be a lowercase UUID: {0:?}")]
    Invalid(String),
}

/// Generate a fresh lowercase UUID v4 session id.
#[must_use]
pub fn new_session_id() -> String {
    Uuid::new_v4().to_string()
}

/// # Errors
/// Returns `IdError::Invalid` when the id is not a canonical lowercase UUID.
pub fn validate(id: &str) -> Result<(), IdError> {
    is_canonical_lowercase_uuid(id)
        .then_some(())
        .ok_or_else(|| IdError::Invalid(id.to_string()))
}

fn is_canonical_lowercase_uuid(id: &str) -> bool {
    id.len() == SESSION_ID_LEN
        && id.bytes().enumerate().all(|(idx, byte)| match idx {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
}

#[cfg(test)]
#[path = "ids/tests.rs"]
mod tests;

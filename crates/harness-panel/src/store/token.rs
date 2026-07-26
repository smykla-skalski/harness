//! Opaque tokens, and the hash the panel stores instead of them.

use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};

use crate::error::PanelError;

/// 256 bits, so the value is not guessable and no rate limit has to stand in
/// for entropy.
const TOKEN_BYTES: usize = 32;

/// A value the panel hands out once and never stores in the clear.
#[derive(Clone, PartialEq, Eq)]
pub struct OpaqueToken {
    value: String,
}

impl OpaqueToken {
    /// Draw a fresh token from the operating system.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails,
    /// which leaves the panel unable to issue sessions at all.
    pub fn generate() -> Result<Self, PanelError> {
        let mut bytes = [0_u8; TOKEN_BYTES];
        getrandom::fill(&mut bytes).map_err(|error| {
            PanelError::config(format!("the system random source is unavailable: {error}"))
        })?;
        Ok(Self {
            value: URL_SAFE_NO_PAD.encode(bytes),
        })
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        &self.value
    }

    #[must_use]
    pub fn hash(&self) -> String {
        hash_token(&self.value)
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_value_for_tests(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
        }
    }
}

/// A session cookie and an OAuth state value both end up in logs, proxies, and
/// browser history if anything prints them, so the token redacts itself.
impl fmt::Debug for OpaqueToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OpaqueToken")
            .field("value", &"<redacted>")
            .finish()
    }
}

/// Hash a token the way the store keys it.
///
/// A plain SHA-256 is the right cost here: the input is 256 random bits, so
/// there is no candidate list to iterate and nothing for a slow KDF to buy.
#[must_use]
pub fn hash_token(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::{OpaqueToken, hash_token};

    #[test]
    fn a_generated_token_is_url_safe_and_long_enough_to_be_unguessable() {
        let token = OpaqueToken::generate().expect("system randomness");

        assert_eq!(token.expose().len(), 43);
        assert!(
            token.expose().chars().all(
                |character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            ),
            "{}",
            token.expose()
        );
    }

    #[test]
    fn two_tokens_differ() {
        let first = OpaqueToken::generate().expect("system randomness");
        let second = OpaqueToken::generate().expect("system randomness");

        assert_ne!(first.expose(), second.expose());
    }

    /// Lookup hashes the presented value and compares it against the stored
    /// one, so the two spellings of the hash have to agree exactly.
    #[test]
    fn hashing_a_token_matches_hashing_its_value() {
        let token = OpaqueToken::from_value_for_tests("abc");

        assert_eq!(token.hash(), hash_token("abc"));
        assert_ne!(token.hash(), hash_token("abd"));
        assert_eq!(token.hash().len(), 64);
    }

    #[test]
    fn debug_output_hides_the_token() {
        let token = OpaqueToken::from_value_for_tests("super-secret");

        assert!(!format!("{token:?}").contains("super-secret"));
    }
}

use sha2::{Digest, Sha256};

const SHA256_STORAGE_PREFIX: &str = "sha256:";
const SHA256_STORAGE_HEX_LEN: usize = 64;

#[must_use]
pub(crate) fn sha256_digest(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

#[must_use]
pub(crate) fn sha256_storage_value(value: &str) -> String {
    format!(
        "{SHA256_STORAGE_PREFIX}{}",
        hex::encode(sha256_digest(value))
    )
}

#[must_use]
pub(crate) fn parse_sha256_storage_digest(value: &str) -> Option<[u8; 32]> {
    let hex_value = value.strip_prefix(SHA256_STORAGE_PREFIX)?;
    if hex_value.len() != SHA256_STORAGE_HEX_LEN {
        return None;
    }
    let mut digest = [0_u8; 32];
    hex::decode_to_slice(hex_value, &mut digest).ok()?;
    Some(digest)
}

#[must_use]
pub(crate) fn constant_time_eq_32(left: &[u8; 32], right: &[u8; 32]) -> bool {
    let diff = left
        .iter()
        .zip(right.iter())
        .fold(0_u8, |acc, (&left, &right)| acc | (left ^ right));
    diff == 0
}

#[must_use]
pub(crate) fn verify_sha256_storage_value(storage_value: &str, candidate_value: &str) -> bool {
    let candidate = sha256_digest(candidate_value);
    let Some(expected) = parse_sha256_storage_digest(storage_value) else {
        let _ = constant_time_eq_32(&[0_u8; 32], &candidate);
        return false;
    };
    constant_time_eq_32(&expected, &candidate)
}

#[cfg(test)]
mod tests {
    use super::{
        constant_time_eq_32, parse_sha256_storage_digest, sha256_storage_value,
        verify_sha256_storage_value,
    };

    #[test]
    fn sha256_storage_value_round_trips_through_shared_verifier() {
        let storage_value = sha256_storage_value("remote-secret");

        assert!(storage_value.starts_with("sha256:"));
        assert_eq!(storage_value.len(), "sha256:".len() + 64);
        assert!(parse_sha256_storage_digest(&storage_value).is_some());
        assert!(verify_sha256_storage_value(&storage_value, "remote-secret"));
        assert!(!verify_sha256_storage_value(&storage_value, "wrong-secret"));
    }

    #[test]
    fn parse_sha256_storage_digest_rejects_malformed_values() {
        assert!(parse_sha256_storage_digest("remote-secret").is_none());
        assert!(parse_sha256_storage_digest("sha256:abc").is_none());
        assert!(parse_sha256_storage_digest(&format!("sha256:{}", "z".repeat(64))).is_none());
    }

    #[test]
    fn constant_time_eq_32_reports_equal_and_different_digests() {
        let left = [1_u8; 32];
        let mut right = [1_u8; 32];

        assert!(constant_time_eq_32(&left, &right));
        right[31] = 2;
        assert!(!constant_time_eq_32(&left, &right));
    }
}

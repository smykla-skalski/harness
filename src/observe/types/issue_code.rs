use sha2::{Digest, Sha256};

/// Canonical definition lives in `harness-protocol`: `ObserverState` (in
/// `state.rs`) needs this as a real crate dependency rather than a second
/// copy compiled in through this file's `#[path]` include from the daemon
/// facade. See `harness_protocol::observe`.
pub use harness_protocol::observe::IssueCode;

/// Compute a stable 12-char hex issue identity from code + fingerprint.
#[must_use]
pub fn compute_issue_id(code: IssueCode, fingerprint: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(code.to_string().as_bytes());
    hasher.update(b"\0");
    hasher.update(fingerprint.as_bytes());
    let digest = hasher.finalize();
    hex::encode(&digest[..6])
}

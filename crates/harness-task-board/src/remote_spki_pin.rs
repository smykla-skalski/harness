use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

const PREFIX: &str = "sha256/";

// `pub` rather than `pub(crate)`: the root crate's remote-execution transport
// and certificate-identity code call these directly today, the minimum this
// crate boundary requires.
#[must_use]
pub fn encode(digest: [u8; 32]) -> String {
    format!("{PREFIX}{}", STANDARD.encode(digest))
}

#[must_use]
pub fn decode(value: &str) -> Option<[u8; 32]> {
    let encoded = value.strip_prefix(PREFIX)?;
    let digest: [u8; 32] = STANDARD.decode(encoded).ok()?.try_into().ok()?;
    (encode(digest) == value).then_some(digest)
}

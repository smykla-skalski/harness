//! Where the daemon is, and what the panel is allowed to mint from it.

use url::Url;

use crate::daemon_client::tls::SpkiPin;
use crate::error::PanelError;

pub const DEFAULT_PAIR_LINK_ROLE: &str = "operator";
pub const DEFAULT_PAIR_LINK_TTL_SECONDS: u64 = 600;

/// The daemon's own ceiling on a minted link's lifetime. Refused here as well
/// so an operator learns at start rather than on somebody's first attempt.
pub const MAX_PAIR_LINK_TTL_SECONDS: u64 = 24 * 60 * 60;

/// The role a broker credential holds. Minting one would let the panel clone
/// its own credential, which the daemon refuses; refusing it here says so
/// before anybody tries.
const BROKER_ROLE: &str = "pairing_broker";

/// Validated daemon connection settings.
#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub endpoint: Url,
    /// The daemon's domain, which its claim route checks the request against.
    pub domain: String,
    pub spki_pin: SpkiPin,
    /// Present only until the panel has claimed a credential of its own.
    pub pair_code: Option<String>,
    pub link_role: String,
    pub link_ttl_seconds: u64,
}

/// Validate the daemon flags.
///
/// # Errors
/// Returns [`PanelError::Config`] when the endpoint, the pin, the role, or the
/// lifetime is not usable.
pub fn resolve(
    endpoint: &str,
    spki_pin: &str,
    pair_code: Option<&str>,
    link_role: &str,
    link_ttl_seconds: u64,
) -> Result<DaemonConfig, PanelError> {
    let endpoint = Url::parse(endpoint.trim())
        .map_err(|error| PanelError::config(format!("--daemon-endpoint {endpoint:?}: {error}")))?;
    if endpoint.scheme() != "https" {
        // The pin is checked during the TLS handshake, so plain HTTP would
        // carry the panel's bearer token with nothing verifying the far end.
        return Err(PanelError::config(format!(
            "--daemon-endpoint must be https, got {:?}",
            endpoint.scheme()
        )));
    }
    let domain = endpoint
        .host_str()
        .ok_or_else(|| PanelError::config("--daemon-endpoint has no host"))?
        .to_owned();

    let link_role = link_role.trim().to_owned();
    if link_role.is_empty() {
        return Err(PanelError::config("--pair-link-role must not be blank"));
    }
    if link_role == BROKER_ROLE {
        return Err(PanelError::config(format!(
            "--pair-link-role must not be {BROKER_ROLE}: a link with that role would let whoever \
             claims it mint links of their own"
        )));
    }

    if link_ttl_seconds == 0 || link_ttl_seconds > MAX_PAIR_LINK_TTL_SECONDS {
        return Err(PanelError::config(format!(
            "--pair-link-ttl-seconds must be between 1 and {MAX_PAIR_LINK_TTL_SECONDS}"
        )));
    }

    let pair_code = pair_code
        .map(str::trim)
        .filter(|code| !code.is_empty())
        .map(str::to_owned);

    Ok(DaemonConfig {
        endpoint,
        domain,
        spki_pin: SpkiPin::parse(spki_pin)?,
        pair_code,
        link_role,
        link_ttl_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        BROKER_ROLE, DEFAULT_PAIR_LINK_ROLE, DaemonConfig, MAX_PAIR_LINK_TTL_SECONDS, resolve,
    };
    use crate::error::PanelError;
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    fn pin() -> String {
        format!("sha256/{}", STANDARD.encode([3_u8; 32]))
    }

    fn resolved(endpoint: &str) -> Result<DaemonConfig, PanelError> {
        resolve(endpoint, &pin(), None, DEFAULT_PAIR_LINK_ROLE, 600)
    }

    #[test]
    fn resolves_a_complete_daemon_configuration() {
        let config = resolved("https://harness.example.com").expect("valid configuration");

        assert_eq!(config.domain, "harness.example.com");
        assert_eq!(config.link_role, "operator");
        assert_eq!(config.link_ttl_seconds, 600);
        assert!(config.pair_code.is_none());
    }

    /// The pin is checked during the handshake, so plain HTTP would carry the
    /// panel's bearer token with nothing verifying the far end.
    #[test]
    fn refuses_a_daemon_endpoint_that_is_not_https() {
        for raw in ["http://harness.example.com", "http://127.0.0.1:8443"] {
            let error = resolved(raw).expect_err("plain http must be refused");
            assert!(error.to_string().contains("https"), "{raw}: {error}");
        }
    }

    /// A link carrying the broker role would let whoever claims it mint links
    /// of their own. The daemon refuses it too; refusing here names the reason
    /// at start rather than on somebody's first attempt.
    #[test]
    fn refuses_minting_the_role_the_panel_itself_holds() {
        let error = resolve(
            "https://harness.example.com",
            &pin(),
            None,
            BROKER_ROLE,
            600,
        )
        .expect_err("the broker role must be refused");

        assert!(error.to_string().contains(BROKER_ROLE), "{error}");
    }

    #[test]
    fn refuses_a_lifetime_the_daemon_would_reject() {
        for ttl in [0, MAX_PAIR_LINK_TTL_SECONDS + 1] {
            let error = resolve(
                "https://harness.example.com",
                &pin(),
                None,
                DEFAULT_PAIR_LINK_ROLE,
                ttl,
            )
            .expect_err("an out-of-range lifetime must be refused");
            assert!(
                error.to_string().contains("--pair-link-ttl-seconds"),
                "{ttl}"
            );
        }
        assert!(
            resolve(
                "https://harness.example.com",
                &pin(),
                None,
                DEFAULT_PAIR_LINK_ROLE,
                MAX_PAIR_LINK_TTL_SECONDS,
            )
            .is_ok(),
            "the bound itself is usable"
        );
    }

    /// A blank code is what an unset environment variable expands to, and
    /// claiming with it would fail against the daemon rather than here.
    #[test]
    fn a_blank_pair_code_is_no_code_at_all() {
        for raw in [Some(""), Some("   "), None] {
            let config = resolve(
                "https://harness.example.com",
                &pin(),
                raw,
                DEFAULT_PAIR_LINK_ROLE,
                600,
            )
            .expect("valid configuration");
            assert!(config.pair_code.is_none(), "{raw:?}");
        }
    }

    #[test]
    fn refuses_a_malformed_pin() {
        let error = resolve(
            "https://harness.example.com",
            "not-a-pin",
            None,
            DEFAULT_PAIR_LINK_ROLE,
            600,
        )
        .expect_err("a malformed pin must be refused");

        assert!(error.to_string().contains("--daemon-spki-pin"), "{error}");
    }
}

//! Where the daemon is, and what the panel is allowed to mint from it.

use url::Url;

use crate::daemon_client::tls::SpkiPin;
use crate::error::PanelError;

pub const DEFAULT_PAIR_LINK_ROLE: &str = "operator";
pub const DEFAULT_PAIR_LINK_TTL_SECONDS: u64 = 600;

/// The daemon's own ceiling on a minted link's lifetime. Refused here as well
/// so an operator learns at start rather than on somebody's first attempt.
pub const MAX_PAIR_LINK_TTL_SECONDS: u64 = 24 * 60 * 60;

/// The role the panel's own credential holds.
pub const BROKER_ROLE: &str = "pairing_broker";

/// Roles a minted link may grant.
///
/// An allow-list, not a deny-list. The panel holds a credential whose only
/// power is minting, and the daemon does not check that a requested role is at
/// or below the caller's own, so a deny-list that happened to name the one role
/// somebody thought of would still let `admin` through and hand every approved
/// account more authority than the panel itself has.
const MINTABLE_ROLES: [&str; 2] = ["operator", "viewer"];

/// Validated daemon connection settings.
#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub endpoint: Url,
    /// The daemon's domain, which its claim route checks the request against.
    pub domain: String,
    pub spki_pin: SpkiPin,
    pub link_role: String,
    pub link_ttl_seconds: u64,
}

fn is_loopback(endpoint: &Url) -> bool {
    endpoint.host().is_some_and(|host| match host {
        url::Host::Domain(domain) => domain.eq_ignore_ascii_case("localhost"),
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    })
}

/// Validate the daemon flags.
///
/// # Errors
/// Returns [`PanelError::Config`] when the endpoint, the pin, the role, or the
/// lifetime is not usable.
pub fn resolve(
    endpoint: &str,
    spki_pin: &str,
    link_role: &str,
    link_ttl_seconds: u64,
) -> Result<DaemonConfig, PanelError> {
    let endpoint = Url::parse(endpoint.trim())
        .map_err(|error| PanelError::config(format!("--daemon-endpoint {endpoint:?}: {error}")))?;
    // The pin is checked during the TLS handshake, so plain HTTP would carry the
    // panel's bearer token with nothing verifying the far end. Loopback is the
    // exception: nothing leaves the host, and the tests need a stub daemon.
    if endpoint.scheme() != "https" && !is_loopback(&endpoint) {
        return Err(PanelError::config(format!(
            "--daemon-endpoint must be https away from loopback, got {:?}",
            endpoint.scheme()
        )));
    }
    let domain = endpoint
        .host_str()
        .ok_or_else(|| PanelError::config("--daemon-endpoint has no host"))?
        .to_owned();

    let link_role = link_role.trim().to_owned();
    if !MINTABLE_ROLES.contains(&link_role.as_str()) {
        return Err(PanelError::config(format!(
            "--pair-link-role must be one of {}, got {link_role:?}. A link may not grant more than \
             the panel is trusted to hand out, and the daemon does not check that for us",
            MINTABLE_ROLES.join(", ")
        )));
    }

    if link_ttl_seconds == 0 || link_ttl_seconds > MAX_PAIR_LINK_TTL_SECONDS {
        return Err(PanelError::config(format!(
            "--pair-link-ttl-seconds must be between 1 and {MAX_PAIR_LINK_TTL_SECONDS}"
        )));
    }

    Ok(DaemonConfig {
        endpoint,
        domain,
        spki_pin: SpkiPin::parse(spki_pin)?,
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
        resolve(endpoint, &pin(), DEFAULT_PAIR_LINK_ROLE, 600)
    }

    #[test]
    fn resolves_a_complete_daemon_configuration() {
        let config = resolved("https://harness.example.com").expect("valid configuration");

        assert_eq!(config.domain, "harness.example.com");
        assert_eq!(config.link_role, "operator");
        assert_eq!(config.link_ttl_seconds, 600);
    }

    /// The pin is checked during the handshake, so plain HTTP would carry the
    /// panel's bearer token with nothing verifying the far end.
    #[test]
    fn refuses_a_daemon_endpoint_that_is_not_https() {
        let error = resolved("http://harness.example.com").expect_err("plain http must be refused");
        assert!(error.to_string().contains("https"), "{error}");

        // Loopback never leaves the host, and the tests need a stub daemon.
        assert!(resolved("http://127.0.0.1:8443").is_ok());
    }

    /// A pinned handshake cannot happen over plain HTTP, so a loopback endpoint
    /// is the one case where the pin is not what protects the token.
    #[test]
    fn a_loopback_daemon_endpoint_is_accepted() {
        assert!(resolved("http://localhost:8443").is_ok());
        assert!(resolved("http://[::1]:8443").is_ok());
    }

    /// A link carrying the broker role would let whoever claims it mint links
    /// of their own. The daemon refuses it too; refusing here names the reason
    /// at start rather than on somebody's first attempt.
    #[test]
    fn refuses_minting_the_role_the_panel_itself_holds() {
        let error = resolve("https://harness.example.com", &pin(), BROKER_ROLE, 600)
            .expect_err("the broker role must be refused");

        assert!(error.to_string().contains("--pair-link-role"), "{error}");
    }

    /// A deny-list naming only the role somebody thought of would let `admin`
    /// through, and the daemon does not check that a requested role is at or
    /// below the caller's own. Every approved account would then be able to
    /// mint more authority than the panel itself holds.
    #[test]
    fn refuses_a_role_more_privileged_than_the_panel_hands_out() {
        for role in [
            "admin",
            "Admin",
            "root",
            "",
            "execution_coordinator",
            "pairing_broker",
        ] {
            let error = resolve("https://harness.example.com", &pin(), role, 600)
                .expect_err(&format!("{role:?} must be refused"));
            assert!(error.to_string().contains("--pair-link-role"), "{role:?}");
        }
    }

    /// Surrounding whitespace is what a copied value carries, and refusing it
    /// would be a puzzle rather than a safeguard.
    #[test]
    fn accepts_the_roles_a_link_may_grant() {
        for role in ["operator", "viewer", " operator ", "viewer\n"] {
            assert!(
                resolve("https://harness.example.com", &pin(), role, 600).is_ok(),
                "{role} should be accepted"
            );
        }
    }

    #[test]
    fn refuses_a_lifetime_the_daemon_would_reject() {
        for ttl in [0, MAX_PAIR_LINK_TTL_SECONDS + 1] {
            let error = resolve(
                "https://harness.example.com",
                &pin(),
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
                DEFAULT_PAIR_LINK_ROLE,
                MAX_PAIR_LINK_TTL_SECONDS,
            )
            .is_ok(),
            "the bound itself is usable"
        );
    }

    #[test]
    fn refuses_a_malformed_pin() {
        let error = resolve(
            "https://harness.example.com",
            "not-a-pin",
            DEFAULT_PAIR_LINK_ROLE,
            600,
        )
        .expect_err("a malformed pin must be refused");

        assert!(error.to_string().contains("--daemon-spki-pin"), "{error}");
    }
}

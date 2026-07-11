use std::fmt;
use std::net::Ipv4Addr;

pub const LETS_ENCRYPT_STAGING_DIRECTORY: &str =
    "https://acme-staging-v02.api.letsencrypt.org/directory";
const DEFAULT_AFTERMARKET_API_BASE: &str = "https://json.aftermarket.pl";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PublicAcmeChallenge {
    TlsAlpn,
    Http,
    Dns,
}

impl PublicAcmeChallenge {
    pub const ALL: [Self; 3] = [Self::TlsAlpn, Self::Http, Self::Dns];

    pub const fn cli_name(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls-alpn",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }

    const fn label(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }
}

pub struct PublicAcmeConfig {
    pub base_domain: String,
    pub ipv4: Ipv4Addr,
    pub email: String,
    pub zone_name: String,
    pub api_base: String,
    pub api_key: String,
    pub api_secret: String,
}

impl PublicAcmeConfig {
    pub fn from_environment() -> Result<Self, String> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    fn from_lookup(mut lookup: impl FnMut(&str) -> Option<String>) -> Result<Self, String> {
        let base_domain = normalized_domain(
            "HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN",
            &required(&mut lookup, "HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN")?,
        )?;
        let ipv4 = required(&mut lookup, "HARNESS_TEST_PUBLIC_ACME_IPV4")?
            .parse::<Ipv4Addr>()
            .map_err(|_| {
                "HARNESS_TEST_PUBLIC_ACME_IPV4 must be a public IPv4 address".to_string()
            })?;
        if !is_public_ipv4(ipv4) {
            return Err("HARNESS_TEST_PUBLIC_ACME_IPV4 must be a public IPv4 address".to_string());
        }
        let email = validated_email(&required(&mut lookup, "HARNESS_TEST_PUBLIC_ACME_EMAIL")?)?;
        let zone_name = normalized_domain(
            "AFTERMARKET_ZONE_NAME",
            &required(&mut lookup, "AFTERMARKET_ZONE_NAME")?,
        )?;
        if !domain_is_within_zone(&base_domain, &zone_name) {
            return Err(format!(
                "public ACME base domain {base_domain} is outside Aftermarket zone {zone_name}"
            ));
        }
        let api_base = public_aftermarket_api_base(
            lookup("HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE").as_deref(),
        )?;
        Ok(Self {
            base_domain,
            ipv4,
            email,
            zone_name,
            api_base,
            api_key: required(&mut lookup, "AFTERMARKET_API_KEY")?,
            api_secret: required(&mut lookup, "AFTERMARKET_API_SECRET")?,
        })
    }

    pub fn case_domain(&self, challenge: PublicAcmeChallenge, nonce: &str) -> String {
        format!("{}-{nonce}.{}", challenge.label(), self.base_domain)
    }
}

fn required(lookup: &mut impl FnMut(&str) -> Option<String>, name: &str) -> Result<String, String> {
    lookup(name)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("public ACME proof requires {name}"))
}

fn normalized_domain(label: &str, value: &str) -> Result<String, String> {
    let domain = value.trim().trim_end_matches('.').to_ascii_lowercase();
    let valid = !domain.is_empty() && domain.len() <= 253 && domain.split('.').all(valid_dns_label);
    if valid {
        Ok(domain)
    } else {
        Err(format!("{label} must be a valid DNS name"))
    }
}

fn valid_dns_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 63
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn domain_is_within_zone(domain: &str, zone: &str) -> bool {
    domain == zone
        || domain
            .strip_suffix(zone)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

fn validated_email(value: &str) -> Result<String, String> {
    let email = value.trim();
    let valid = email.split_once('@').is_some_and(|(local, domain)| {
        !local.is_empty() && normalized_domain("email", domain).is_ok()
    });
    if valid {
        Ok(email.to_string())
    } else {
        Err("HARNESS_TEST_PUBLIC_ACME_EMAIL must be a valid email address".to_string())
    }
}

fn validated_api_base(value: &str) -> Result<String, String> {
    let value = value.trim().trim_end_matches('/');
    let url = reqwest::Url::parse(value).map_err(|_| {
        "HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE must be a valid HTTPS URL".to_string()
    })?;
    let valid = url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none();
    if valid {
        Ok(value.to_string())
    } else {
        Err("HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE must be a valid HTTPS URL".to_string())
    }
}

fn public_aftermarket_api_base(configured: Option<&str>) -> Result<String, String> {
    let api_base = validated_api_base(configured.unwrap_or(DEFAULT_AFTERMARKET_API_BASE))?;
    if api_base != DEFAULT_AFTERMARKET_API_BASE {
        return Err(format!(
            "public ACME proof pins HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE to {DEFAULT_AFTERMARKET_API_BASE}"
        ));
    }
    Ok(api_base)
}

fn is_public_ipv4(address: Ipv4Addr) -> bool {
    let [first, second, third, _] = address.octets();
    !address.is_private()
        && !address.is_loopback()
        && !address.is_link_local()
        && !address.is_documentation()
        && !address.is_broadcast()
        && !address.is_multicast()
        && !address.is_unspecified()
        && first < 224
        && first != 0
        && !(first == 100 && (64..=127).contains(&second))
        && !(first == 192 && second == 0 && third == 0)
        && !(first == 198 && (18..=19).contains(&second))
}

impl fmt::Debug for PublicAcmeConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PublicAcmeConfig")
            .field("base_domain", &self.base_domain)
            .field("ipv4", &self.ipv4)
            .field("email", &self.email)
            .field("zone_name", &self.zone_name)
            .field("api_base", &self.api_base)
            .field("api_key", &"<redacted>")
            .field("api_secret", &"<redacted>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[test]
    #[expect(
        clippy::cognitive_complexity,
        reason = "assertion macro expansion for one complete configuration contract"
    )]
    fn public_acme_config_accepts_complete_staging_proof_inputs() {
        let config = config_from([
            ("HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN", "remote.example.com"),
            ("HARNESS_TEST_PUBLIC_ACME_IPV4", "8.8.8.8"),
            ("HARNESS_TEST_PUBLIC_ACME_EMAIL", "ops@example.com"),
            ("AFTERMARKET_ZONE_NAME", "example.com"),
            ("AFTERMARKET_API_KEY", "public-key"),
            ("AFTERMARKET_API_SECRET", "secret-key"),
        ])
        .expect("valid public ACME config");

        assert_eq!(config.base_domain, "remote.example.com");
        assert_eq!(config.ipv4, Ipv4Addr::new(8, 8, 8, 8));
        assert_eq!(config.email, "ops@example.com");
        assert_eq!(config.zone_name, "example.com");
        assert_eq!(config.api_base, DEFAULT_AFTERMARKET_API_BASE);
        assert_eq!(config.api_key, "public-key");
        assert_eq!(config.api_secret, "secret-key");
        assert_eq!(
            LETS_ENCRYPT_STAGING_DIRECTORY,
            "https://acme-staging-v02.api.letsencrypt.org/directory"
        );
        assert_eq!(
            config.case_domain(PublicAcmeChallenge::TlsAlpn, "20260711"),
            "tls-20260711.remote.example.com"
        );
        assert_eq!(
            PublicAcmeChallenge::ALL.map(PublicAcmeChallenge::cli_name),
            ["tls-alpn", "http", "dns"]
        );
    }

    #[test]
    fn public_acme_config_rejects_private_or_unspecified_addresses() {
        for address in ["127.0.0.1", "10.0.0.7", "0.0.0.0"] {
            let error = config_from([
                ("HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN", "remote.example.com"),
                ("HARNESS_TEST_PUBLIC_ACME_IPV4", address),
                ("HARNESS_TEST_PUBLIC_ACME_EMAIL", "ops@example.com"),
                ("AFTERMARKET_ZONE_NAME", "example.com"),
                ("AFTERMARKET_API_KEY", "public-key"),
                ("AFTERMARKET_API_SECRET", "secret-key"),
            ])
            .expect_err("non-public address must be rejected");

            assert!(error.contains("public IPv4"), "unexpected error: {error}");
        }
    }

    #[test]
    fn public_acme_config_rejects_base_domain_outside_zone() {
        let error = config_from([
            ("HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN", "remote.example.net"),
            ("HARNESS_TEST_PUBLIC_ACME_IPV4", "8.8.8.8"),
            ("HARNESS_TEST_PUBLIC_ACME_EMAIL", "ops@example.com"),
            ("AFTERMARKET_ZONE_NAME", "example.com"),
            ("AFTERMARKET_API_KEY", "public-key"),
            ("AFTERMARKET_API_SECRET", "secret-key"),
        ])
        .expect_err("out-of-zone domain must be rejected");

        assert!(error.contains("outside Aftermarket zone"));
    }

    #[test]
    fn public_acme_config_rejects_aftermarket_endpoint_override() {
        let error = config_from([
            ("HARNESS_TEST_PUBLIC_ACME_BASE_DOMAIN", "remote.example.com"),
            ("HARNESS_TEST_PUBLIC_ACME_IPV4", "8.8.8.8"),
            ("HARNESS_TEST_PUBLIC_ACME_EMAIL", "ops@example.com"),
            ("AFTERMARKET_ZONE_NAME", "example.com"),
            ("AFTERMARKET_API_KEY", "public-key"),
            ("AFTERMARKET_API_SECRET", "secret-key"),
            (
                "HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE",
                "https://redirect.example.net",
            ),
        ])
        .expect_err("credential destination override must be rejected");

        assert!(error.contains("pins HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE"));
    }

    #[test]
    fn public_acme_config_debug_redacts_credentials() {
        let config = PublicAcmeConfig {
            base_domain: "remote.example.com".to_string(),
            ipv4: Ipv4Addr::new(8, 8, 8, 8),
            email: "ops@example.com".to_string(),
            zone_name: "example.com".to_string(),
            api_base: DEFAULT_AFTERMARKET_API_BASE.to_string(),
            api_key: "public-key".to_string(),
            api_secret: "secret-key".to_string(),
        };

        let debug = format!("{config:?}");
        assert!(!debug.contains("public-key"));
        assert!(!debug.contains("secret-key"));
        assert_eq!(debug.matches("<redacted>").count(), 2);
    }

    fn config_from<const N: usize>(values: [(&str, &str); N]) -> Result<PublicAcmeConfig, String> {
        let values = values
            .into_iter()
            .map(|(name, value)| (name.to_string(), value.to_string()))
            .collect::<HashMap<_, _>>();
        PublicAcmeConfig::from_lookup(|name| values.get(name).cloned())
    }
}

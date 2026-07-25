//! The panel's one link to the daemon.
//!
//! Two calls, both over the daemon's public HTTPS listener: claiming the
//! credential the panel runs as, once, and minting a pairing link for a person
//! the panel has authenticated. The panel never reads the daemon's database or
//! runs its CLI; this module is the whole of the coupling.

pub mod tls;

use std::time::Duration;

use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderName, USER_AGENT};
use reqwest::{Client, Response, StatusCode};
use serde::{Deserialize, Serialize};
use url::Url;

use crate::config::daemon::DaemonConfig;
use crate::crypto::ensure_crypto_provider;
use crate::error::PanelError;
use crate::store::accounts::Account;
use tls::pinned_client_config;

/// The header the daemon reads a remote client's identity from.
const CLIENT_ID_HEADER: &str = "x-harness-remote-client-id";

/// Long enough for the daemon to mint and persist a link, short enough that a
/// stalled daemon does not hold a browser request open indefinitely.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// What the panel tells the daemon it is, so an operator listing paired clients
/// can see which one is the panel.
const CLIENT_PLATFORM: &str = "harness-panel";

/// The credential the panel authenticates to the daemon with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonCredential {
    pub client_id: String,
    pub token: String,
    pub role: String,
}

/// A link the daemon minted, as the panel hands it on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MintedLink {
    pub pairing_id: String,
    pub role: String,
    pub scopes: Vec<String>,
    pub expires_at: String,
    /// The `harness://pair` link. It carries the one-time code, so the panel
    /// shows it once and stores none of it.
    pub pairing_url: String,
}

/// Talks to one daemon, over a connection pinned to its certificate.
#[derive(Debug, Clone)]
pub struct DaemonClient {
    http: Client,
    endpoint: Url,
    domain: String,
}

impl DaemonClient {
    /// Build a client pinned to the configured daemon.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the pin or the endpoint is unusable
    /// and [`PanelError::GitHub`] never; daemon failures surface at call time.
    pub fn new(config: &DaemonConfig) -> Result<Self, PanelError> {
        ensure_crypto_provider();
        let tls = pinned_client_config(config.spki_pin)?;
        let http = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .use_preconfigured_tls(tls)
            .build()
            .map_err(|error| {
                PanelError::config(format!("building the daemon HTTP client: {error}"))
            })?;
        Ok(Self {
            http,
            endpoint: config.endpoint.clone(),
            domain: config.domain.clone(),
        })
    }

    /// Spend a one-time pairing code for the credential the panel will run as.
    ///
    /// # Errors
    /// Returns [`PanelError::Daemon`] when the daemon refuses the code or
    /// cannot be reached.
    pub async fn claim(&self, code: &str, client_id: &str) -> Result<DaemonCredential, PanelError> {
        let response = self
            .post(self.route("/v1/remote/pair/claim"))
            .json(&ClaimRequest {
                code,
                domain: &self.domain,
                client_id,
                display_name: "Harness panel",
                platform: CLIENT_PLATFORM,
            })
            .send()
            .await
            .map_err(|error| PanelError::daemon(format!("claiming the pairing code: {error}")))?;

        let claimed: ClaimResponse = read_json(response, "claim the pairing code").await?;
        Ok(DaemonCredential {
            client_id: claimed.client_id,
            token: claimed.token,
            role: claimed.role,
        })
    }

    /// Mint a pairing link for `account`.
    ///
    /// The role, the scopes, and the lifetime come from the panel's own
    /// configuration. Letting a request choose them would make every approved
    /// account able to issue itself a credential the owner never intended.
    ///
    /// # Errors
    /// Returns [`PanelError::Daemon`] when the daemon refuses the request or
    /// cannot be reached.
    pub async fn mint(
        &self,
        credential: &DaemonCredential,
        account: &Account,
        role: &str,
        ttl_seconds: u64,
    ) -> Result<MintedLink, PanelError> {
        let response = self
            .post(self.route("/v1/remote/pair/mint"))
            .header(
                HeaderName::from_static(CLIENT_ID_HEADER),
                credential.client_id.clone(),
            )
            .header(AUTHORIZATION, format!("Bearer {}", credential.token))
            .json(&MintRequest {
                role,
                ttl_seconds,
                subject: MintSubject {
                    provider: &account.provider,
                    subject_id: &account.subject_id,
                    display_name: &account.display_name,
                },
            })
            .send()
            .await
            .map_err(|error| PanelError::daemon(format!("minting a pairing link: {error}")))?;

        let minted: MintResponse = read_json(response, "mint a pairing link").await?;
        Ok(MintedLink {
            pairing_id: minted.pairing_id,
            role: minted.role,
            scopes: minted.scopes,
            expires_at: minted.expires_at,
            pairing_url: minted.pairing_url,
        })
    }

    fn route(&self, path: &str) -> Url {
        let mut url = self.endpoint.clone();
        url.set_path(path);
        url
    }

    fn post(&self, url: Url) -> reqwest::RequestBuilder {
        self.http
            .post(url)
            .header(ACCEPT, "application/json")
            .header(CONTENT_TYPE, "application/json")
            .header(
                USER_AGENT,
                concat!("harness-panel/", env!("CARGO_PKG_VERSION")),
            )
    }
}

/// Read a daemon answer, keeping its own message when it refused.
///
/// The daemon's error bodies name the reason precisely, and an operator reading
/// the panel's log needs that rather than a status code on its own. The body is
/// bounded by the daemon's own limits, and none of it reaches the browser: the
/// caller turns this into a fixed sentence.
async fn read_json<T>(response: Response, action: &str) -> Result<T, PanelError>
where
    T: for<'de> Deserialize<'de>,
{
    let status = response.status();
    if status.is_success() {
        return response
            .json()
            .await
            .map_err(|error| PanelError::daemon(format!("reading the daemon answer: {error}")));
    }

    let detail = response.text().await.unwrap_or_default();
    let detail = detail.trim();
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(PanelError::daemon(format!(
            "the daemon refused the panel's credential ({status}); it may need re-pairing: {detail}"
        )));
    }
    Err(PanelError::daemon(format!(
        "could not {action}: the daemon answered {status}: {detail}"
    )))
}

#[derive(Debug, Serialize)]
struct ClaimRequest<'a> {
    code: &'a str,
    domain: &'a str,
    client_id: &'a str,
    display_name: &'a str,
    platform: &'a str,
}

#[derive(Debug, Deserialize)]
struct ClaimResponse {
    client_id: String,
    token: String,
    role: String,
}

#[derive(Debug, Serialize)]
struct MintRequest<'a> {
    role: &'a str,
    ttl_seconds: u64,
    subject: MintSubject<'a>,
}

#[derive(Debug, Serialize)]
struct MintSubject<'a> {
    provider: &'a str,
    subject_id: &'a str,
    display_name: &'a str,
}

#[derive(Debug, Deserialize)]
struct MintResponse {
    pairing_id: String,
    role: String,
    scopes: Vec<String>,
    expires_at: String,
    pairing_url: String,
}

#[cfg(test)]
mod tests;

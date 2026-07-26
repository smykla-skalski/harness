//! The panel's one link to the daemon.
//!
//! Four calls and a socket, all over the daemon's public HTTPS listener:
//! claiming the credential the panel runs as, once; minting a pairing link for
//! a person the panel has authenticated; listing and revoking what it minted;
//! and a websocket held open to be told when one of those pairings changes. The
//! panel never reads the daemon's database or runs its CLI; this module is the
//! whole of the coupling.

pub mod events;
pub mod pairings;
pub mod tls;

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};

use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderName, USER_AGENT};
use reqwest::{Client, Response};
use rustls::ClientConfig;
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
    /// When the daemon says the link lapses, for the person who asked. The
    /// panel does not do arithmetic against its own clock with this: see
    /// [`MintedLink::ttl_seconds`].
    pub expires_at: DateTime<Utc>,
    /// The lifetime the daemon granted, which may be shorter than the one
    /// asked for. A duration rather than an instant, so the panel can date the
    /// link on its own clock instead of comparing two hosts' clocks.
    pub ttl_seconds: u64,
    /// The `harness://pair` link. It carries the one-time code, so the panel
    /// shows it once and stores none of it.
    pub pairing_url: String,
}

/// Whether a failed mint definitely issued nothing.
#[derive(Debug)]
pub enum MintError {
    /// The daemon answered with a refusal. Its mint transaction did not commit.
    NotIssued(PanelError),
    /// The request or answer failed at a point where the daemon may have
    /// committed the link already.
    IssuanceUnknown(PanelError),
}

/// Talks to one daemon, over a connection pinned to its certificate.
#[derive(Debug, Clone)]
pub struct DaemonClient {
    http: Client,
    /// The same configuration `http` was built with, kept because the event
    /// socket has to run its own handshake: reqwest will not hand out the raw
    /// stream a websocket needs, and building a second verifier would be a
    /// second place for the pin to drift.
    tls: Arc<ClientConfig>,
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
            .use_preconfigured_tls(tls.clone())
            .build()
            .map_err(|error| {
                PanelError::config(format!("building the daemon HTTP client: {error}"))
            })?;
        Ok(Self {
            http,
            tls: Arc::new(tls),
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
    /// Returns [`MintError::NotIssued`] when the daemon refuses the request and
    /// [`MintError::IssuanceUnknown`] when it may have committed without
    /// delivering a usable answer.
    pub async fn mint(
        &self,
        credential: &DaemonCredential,
        account: &Account,
        role: &str,
        ttl_seconds: u64,
    ) -> Result<MintedLink, MintError> {
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
            .map_err(|error| {
                MintError::IssuanceUnknown(PanelError::daemon(format!(
                    "minting a pairing link: {error}"
                )))
            })?;

        let minted = read_mint_json(response).await?;
        // Parsed rather than passed through: the panel shows this to the person
        // who asked and stores it beside the pairing id, so an unreadable value
        // would surface as a link with no visible deadline.
        let expires_at = DateTime::parse_from_rfc3339(&minted.expires_at)
            .map_err(|error| {
                MintError::IssuanceUnknown(PanelError::daemon(format!(
                    "the daemon returned an unreadable expiry {:?}: {error}",
                    minted.expires_at
                )))
            })?
            .with_timezone(&Utc);
        Ok(MintedLink {
            pairing_id: checked_pairing_id(minted.pairing_id)
                .map_err(MintError::IssuanceUnknown)?,
            role: minted.role,
            scopes: minted.scopes,
            expires_at,
            ttl_seconds: minted.ttl_seconds,
            pairing_url: minted.pairing_url,
        })
    }

    /// Append a daemon route to the configured endpoint.
    ///
    /// `set_path` would replace the whole path, so an endpoint carrying a
    /// prefix — a daemon behind a reverse proxy at `/harness`, say — would have
    /// it silently dropped and every call would 404 with nothing naming the
    /// cause.
    fn route(&self, path: &str) -> Url {
        let mut url = self.endpoint.clone();
        let base = url.path().trim_end_matches('/').to_owned();
        url.set_path(&format!("{base}{path}"));
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

async fn read_mint_json(response: Response) -> Result<MintResponse, MintError> {
    let status = response.status();
    if status.is_success() {
        return response.json().await.map_err(|error| {
            MintError::IssuanceUnknown(PanelError::daemon(format!(
                "reading the daemon answer: {error}"
            )))
        });
    }

    let detail = response.text().await.unwrap_or_default();
    Err(MintError::NotIssued(PanelError::daemon(format!(
        "could not mint a pairing link: the daemon answered {status}: {}",
        detail.trim()
    ))))
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
    // Deliberately no guess at the cause. A 403 answers a claim whose domain
    // does not match as readily as it answers a stale credential, and naming
    // the wrong one sends an operator to revoke a client when the endpoint was
    // the problem. The daemon's own message says which.
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

/// Longest pairing id the panel will file. The daemon's own identifiers are
/// far shorter; this only stops one being used as free storage.
const MAX_PAIRING_ID_CHARS: usize = 200;

/// The prefix the panel gives a slot it has claimed but not yet filled.
///
/// [`checked_pairing_id`] refuses a daemon pairing spelled this way, which is
/// what lets the store tell its own reservations from real pairings by the id
/// alone.
pub const RESERVATION_PREFIX: &str = "reservation:";

/// Check the identifier the panel will log, store, and quote back.
///
/// It becomes a primary key and a field in three log lines, so a control
/// character in it forges a line in the record an operator reads to reconcile
/// against the daemon, and the reservation prefix would make a real pairing
/// read as a slot abandoned by a crash. The value is refused rather than
/// repaired: a daemon that sends one of these is not one whose links should be
/// handed out, and the message quotes it escaped.
fn checked_pairing_id(pairing_id: String) -> Result<String, PanelError> {
    let refuse = |why: &str| {
        Err(PanelError::daemon(format!(
            "the daemon returned a pairing id that {why}: {pairing_id:?}"
        )))
    };
    if pairing_id.trim().is_empty() {
        return refuse("is blank");
    }
    if pairing_id.chars().any(char::is_control) {
        return refuse("carries control characters");
    }
    if pairing_id.chars().count() > MAX_PAIRING_ID_CHARS {
        return refuse("is longer than the panel will file");
    }
    if pairing_id.starts_with(RESERVATION_PREFIX) {
        return refuse("is spelled like one of the panel's own reservations");
    }
    Ok(pairing_id)
}

#[derive(Debug, Deserialize)]
struct MintResponse {
    pairing_id: String,
    role: String,
    scopes: Vec<String>,
    expires_at: String,
    ttl_seconds: u64,
    pairing_url: String,
}

#[cfg(test)]
mod tests;

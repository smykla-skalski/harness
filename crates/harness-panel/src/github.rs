//! GitHub authorization-code sign-in.
//!
//! The panel asks for `read:user` and nothing else: it needs to know who is at
//! the keyboard, not to act on their behalf. The access token is used once, to
//! read the profile, and is never stored.

use std::time::Duration;

use reqwest::Client;
use reqwest::header::{ACCEPT, AUTHORIZATION, USER_AGENT};
use serde::Deserialize;
use url::Url;

use crate::config::GitHubConfig;
use crate::error::PanelError;
use crate::store::accounts::AccountIdentity;

/// Long enough for a slow round trip, short enough that an unreachable GitHub
/// does not hold a request open until the browser gives up first.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// Enough for any real GitHub profile field. Longer than this is either an
/// enterprise misconfiguration or an attempt to use the panel's account table
/// as storage.
const MAX_FIELD_CHARS: usize = 200;

const PROVIDER: &str = "github";
const SCOPE: &str = "read:user";

/// Talks to GitHub as the panel's OAuth app.
#[derive(Debug, Clone)]
pub struct GitHubClient {
    config: GitHubConfig,
    callback_url: String,
    http: Client,
}

impl GitHubClient {
    /// Build a client that identifies itself and gives up on a stalled request.
    ///
    /// # Errors
    /// Returns [`PanelError::GitHub`] when the HTTP client cannot be built.
    pub fn new(config: GitHubConfig, callback_url: String) -> Result<Self, PanelError> {
        let http = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|error| PanelError::github(format!("building the HTTP client: {error}")))?;
        Ok(Self {
            config,
            callback_url,
            http,
        })
    }

    /// Where to send the browser to start a sign-in.
    #[must_use]
    pub fn authorize_url(&self, state: &str) -> String {
        let mut url = self.config.authorize_url.clone();
        url.query_pairs_mut()
            .append_pair("client_id", &self.config.client_id)
            .append_pair("redirect_uri", &self.callback_url)
            .append_pair("scope", SCOPE)
            .append_pair("state", state)
            // Someone without a GitHub account cannot be an approved pairer, so
            // offering them the sign-up flow only leads them somewhere useless.
            .append_pair("allow_signup", "false");
        url.to_string()
    }

    /// Trade the authorization code for an access token.
    ///
    /// # Errors
    /// Returns [`PanelError::GitHub`] when the request fails or GitHub refuses
    /// the code.
    pub async fn exchange_code(&self, code: &str) -> Result<String, PanelError> {
        let response = self
            .http
            .post(self.config.token_url.clone())
            .header(ACCEPT, "application/json")
            .header(USER_AGENT, panel_user_agent())
            .form(&[
                ("client_id", self.config.client_id.as_str()),
                ("client_secret", self.config.client_secret.expose()),
                ("code", code),
                ("redirect_uri", self.callback_url.as_str()),
            ])
            .send()
            .await
            .map_err(|error| PanelError::github(format!("exchanging the code: {error}")))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|error| PanelError::github(format!("reading the token response: {error}")))?;
        if !status.is_success() {
            return Err(PanelError::github(format!(
                "the token endpoint answered {status}"
            )));
        }
        parse_token_response(&body)
    }

    /// Read the signed-in person's profile.
    ///
    /// # Errors
    /// Returns [`PanelError::GitHub`] when the request fails or the profile is
    /// not one the panel can store.
    pub async fn fetch_identity(&self, access_token: &str) -> Result<AccountIdentity, PanelError> {
        let url = join_api_path(&self.config.api_url, "user");
        let response = self
            .http
            .get(url)
            .header(AUTHORIZATION, format!("Bearer {access_token}"))
            .header(ACCEPT, "application/vnd.github+json")
            .header(USER_AGENT, panel_user_agent())
            .send()
            .await
            .map_err(|error| PanelError::github(format!("reading the profile: {error}")))?;

        let status = response.status();
        if !status.is_success() {
            return Err(PanelError::github(format!(
                "the profile endpoint answered {status}"
            )));
        }
        let user: GitHubUser = response
            .json()
            .await
            .map_err(|error| PanelError::github(format!("parsing the profile: {error}")))?;
        identity_from_user(user)
    }
}

fn panel_user_agent() -> String {
    format!("harness-panel/{}", env!("CARGO_PKG_VERSION"))
}

/// The subset of GitHub's user object the panel records.
#[derive(Debug, Deserialize)]
struct GitHubUser {
    id: u64,
    login: String,
    name: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

/// Pull the access token out of a token-endpoint response.
///
/// GitHub answers a refused code with HTTP 200 and an `error` field, so a
/// caller that only checked the status would go on to call the API with the
/// literal string "None".
fn parse_token_response(body: &str) -> Result<String, PanelError> {
    let parsed: TokenResponse = serde_json::from_str(body)
        .map_err(|error| PanelError::github(format!("parsing the token response: {error}")))?;

    if let Some(error) = parsed.error {
        let detail = parsed.error_description.unwrap_or_else(|| error.clone());
        return Err(PanelError::github(format!(
            "github refused the authorization code: {detail}"
        )));
    }
    match parsed.access_token {
        Some(token) if !token.trim().is_empty() => Ok(token),
        _ => Err(PanelError::github(
            "the token response carried no access token",
        )),
    }
}

/// Turn a GitHub profile into the identity the panel stores.
///
/// The login and display name are rendered into the panel's pages and, in the
/// next slice, into the pairing subject the daemon records, so a control
/// character here would forge structure somewhere downstream. They are refused
/// at the boundary instead of escaped at each sink.
fn identity_from_user(user: GitHubUser) -> Result<AccountIdentity, PanelError> {
    let GitHubUser {
        id,
        login,
        name,
        avatar_url,
    } = user;

    let login = checked_field("login", &login)?;
    let display_name = match name.as_deref().map(str::trim) {
        Some(name) if !name.is_empty() => checked_field("name", name)?,
        // A GitHub profile with no display name is ordinary, and the login is
        // the label the person already recognises.
        _ => login.clone(),
    };
    let avatar_url = avatar_url
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(checked_avatar_url)
        .transpose()?;

    Ok(AccountIdentity {
        provider: PROVIDER.to_owned(),
        subject_id: id.to_string(),
        login,
        display_name,
        avatar_url,
    })
}

fn checked_field(label: &str, value: &str) -> Result<String, PanelError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(PanelError::github(format!("the profile {label} is blank")));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(PanelError::github(format!(
            "the profile {label} contains control characters"
        )));
    }
    if trimmed.chars().count() > MAX_FIELD_CHARS {
        return Err(PanelError::github(format!(
            "the profile {label} is longer than {MAX_FIELD_CHARS} characters"
        )));
    }
    Ok(trimmed.to_owned())
}

/// The avatar becomes an `img` source, so a `javascript:` or `data:` URL would
/// run in the panel's origin the moment an owner opened the account list.
fn checked_avatar_url(value: &str) -> Result<String, PanelError> {
    let parsed = Url::parse(value)
        .map_err(|error| PanelError::github(format!("the profile avatar url: {error}")))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(PanelError::github(format!(
            "the profile avatar url must be http or https, got {:?}",
            parsed.scheme()
        )));
    }
    checked_field("avatar url", value)
}

fn join_api_path(api_url: &Url, path: &str) -> Url {
    // `Url::join` replaces the last path segment unless the base ends in a
    // slash, which would turn a GitHub Enterprise base of `/api/v3` into `/user`.
    let mut base = api_url.clone();
    let trimmed = base.path().trim_end_matches('/').to_owned();
    base.set_path(&format!("{trimmed}/{path}"));
    base
}

#[cfg(test)]
mod tests;

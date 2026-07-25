//! The session cookie, and who it says is signed in.

use axum::http::HeaderMap;
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use chrono::Utc;
use serde::Serialize;

use super::PanelState;
use crate::error::ApiError;
use crate::store::accounts::Account;
use crate::store::token::hash_token;

/// Names the panel's own cookies so they cannot collide with anything else the
/// daemon serves on the same origin.
pub const SESSION_COOKIE: &str = "harness_panel_session";
pub const SIGN_IN_COOKIE_PREFIX: &str = "harness_panel_signin_";

/// The signed-in person, as the single-page app receives them.
#[derive(Debug, Clone, Serialize)]
pub struct Viewer {
    pub account: Account,
    pub is_owner: bool,
}

/// Resolve the request's session cookie to a signed-in person.
///
/// # Errors
/// Returns [`ApiError::Internal`] when the session store cannot be read.
pub async fn current_viewer(
    state: &PanelState,
    headers: &HeaderMap,
) -> Result<Option<Viewer>, ApiError> {
    let Some(token) = session_token(headers) else {
        return Ok(None);
    };
    let Some(session) = state.store.session_for_token(&token, Utc::now()).await? else {
        return Ok(None);
    };

    let is_owner = resolve_ownership(state, &session.account).await?;
    Ok(Some(Viewer {
        account: session.account,
        is_owner,
    }))
}

/// Decide whether `account` owns this panel.
///
/// The successful OAuth callback claims an unowned panel before it returns a
/// session. Reads stay read-only so ownership does not depend on whether the
/// redirected browser loads `/api/me` before the configured login changes.
///
/// # Errors
/// Returns [`ApiError::Internal`] when the owner binding cannot be read.
async fn resolve_ownership(state: &PanelState, account: &Account) -> Result<bool, ApiError> {
    Ok(state
        .store
        .owner_binding()
        .await?
        .is_some_and(|binding| binding.matches(account)))
}

/// Like [`current_viewer`], but treats being signed out as a failure.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when no live session is presented.
pub async fn require_viewer(state: &PanelState, headers: &HeaderMap) -> Result<Viewer, ApiError> {
    current_viewer(state, headers)
        .await?
        .ok_or(ApiError::Unauthenticated)
}

#[must_use]
pub fn session_token(headers: &HeaderMap) -> Option<String> {
    cookie_value(headers, SESSION_COOKIE)
}

#[must_use]
pub fn has_pending_sign_in(headers: &HeaderMap, state: &str) -> bool {
    cookie_value(headers, &sign_in_cookie_name(state)).as_deref() == Some(state)
}

/// Give each OAuth attempt an independent cookie so concurrent start
/// responses do not overwrite one shared browser value.
#[must_use]
pub fn sign_in_cookie_name(state: &str) -> String {
    format!("{SIGN_IN_COOKIE_PREFIX}{}", hash_token(state))
}

fn cookie_value(headers: &HeaderMap, name: &str) -> Option<String> {
    CookieJar::from_headers(headers)
        .get(name)
        .map(|cookie| cookie.value().to_owned())
}

/// Build a cookie the browser will only offer back to the panel.
///
/// `SameSite=Lax` rather than `Strict`, because the sign-in ends with GitHub
/// navigating the browser back here and a `Strict` cookie would not be sent on
/// that first request. `Secure` follows the public origin: the browser drops a
/// `Secure` cookie on a plain-HTTP page, so pinning it on would make loopback
/// development silently never sign anyone in.
fn panel_cookie(
    name: String,
    value: String,
    state: &PanelState,
    max_age: time::Duration,
) -> Cookie<'static> {
    Cookie::build((name, value))
        .http_only(true)
        .same_site(SameSite::Lax)
        .path(state.config.cookie_path().to_owned())
        .secure(state.config.cookie_is_secure())
        .max_age(max_age)
        .build()
}

pub fn with_session_cookie(jar: CookieJar, state: &PanelState, token: String) -> CookieJar {
    let max_age = time::Duration::seconds(state.config.session_ttl.num_seconds());
    jar.add(panel_cookie(
        SESSION_COOKIE.to_owned(),
        token,
        state,
        max_age,
    ))
}

/// Expire a cookie in the browser.
///
/// The attributes have to match the ones it was set with, or the browser keeps
/// the original cookie alongside the expired one and goes on sending it.
pub fn without_cookie(jar: CookieJar, state: &PanelState, name: &'static str) -> CookieJar {
    jar.add(panel_cookie(
        name.to_owned(),
        String::new(),
        state,
        time::Duration::seconds(0),
    ))
}

/// Record one sign-in under a cookie name derived from its state.
pub fn with_pending_sign_in(
    jar: CookieJar,
    state: &PanelState,
    value: String,
    ttl_seconds: i64,
) -> CookieJar {
    let name = sign_in_cookie_name(&value);
    jar.add(panel_cookie(
        name,
        value,
        state,
        time::Duration::seconds(ttl_seconds),
    ))
}

/// Expire only the cookie for this sign-in, leaving every other tab alone.
pub fn without_pending_sign_in(jar: CookieJar, state: &PanelState, value: &str) -> CookieJar {
    jar.add(panel_cookie(
        sign_in_cookie_name(value),
        String::new(),
        state,
        time::Duration::seconds(0),
    ))
}

#[cfg(test)]
mod tests {
    use super::sign_in_cookie_name;

    #[test]
    fn each_state_has_a_stable_independent_cookie_name() {
        let first = sign_in_cookie_name("first");
        let second = sign_in_cookie_name("second");

        assert_eq!(first, sign_in_cookie_name("first"));
        assert_ne!(first, second);
        assert!(first.starts_with("harness_panel_signin_"));
        assert_eq!(first.len(), "harness_panel_signin_".len() + 64);
    }
}

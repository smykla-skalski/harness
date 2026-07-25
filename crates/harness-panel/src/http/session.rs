//! The session cookie, and who it says is signed in.

use axum::http::HeaderMap;
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use chrono::Utc;
use serde::Serialize;

use super::PanelState;
use crate::error::ApiError;
use crate::store::accounts::Account;

/// Names the panel's own cookies so they cannot collide with anything else the
/// daemon serves on the same origin.
pub const SESSION_COOKIE: &str = "harness_panel_session";
pub const SIGN_IN_COOKIE: &str = "harness_panel_signin";

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

    let is_owner = state.config.is_owner(&session.account.login);
    Ok(Some(Viewer {
        account: session.account,
        is_owner,
    }))
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
pub fn sign_in_state(headers: &HeaderMap) -> Option<String> {
    cookie_value(headers, SIGN_IN_COOKIE)
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
fn panel_cookie<'a>(
    name: &'a str,
    value: String,
    state: &PanelState,
    max_age: time::Duration,
) -> Cookie<'a> {
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
    jar.add(panel_cookie(SESSION_COOKIE, token, state, max_age))
}

/// Expire a cookie in the browser.
///
/// The attributes have to match the ones it was set with, or the browser keeps
/// the original cookie alongside the expired one and goes on sending it.
pub fn without_cookie(jar: CookieJar, state: &PanelState, name: &'static str) -> CookieJar {
    jar.add(panel_cookie(
        name,
        String::new(),
        state,
        time::Duration::seconds(0),
    ))
}

pub fn with_sign_in_cookie(
    jar: CookieJar,
    state: &PanelState,
    value: String,
    ttl_seconds: i64,
) -> CookieJar {
    jar.add(panel_cookie(
        SIGN_IN_COOKIE,
        value,
        state,
        time::Duration::seconds(ttl_seconds),
    ))
}

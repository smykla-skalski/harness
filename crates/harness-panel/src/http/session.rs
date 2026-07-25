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

    let is_owner = resolve_ownership(state, &session.account).await?;
    Ok(Some(Viewer {
        account: session.account,
        is_owner,
    }))
}

/// Decide whether `account` owns this panel, claiming it on first use.
///
/// `--owner-login` only chooses who the panel is claimed for. Once claimed, the
/// answer is the immutable `(provider, subject_id)` pair, so renaming the login
/// and letting someone else register the freed name does not hand them the
/// panel. The re-read after the claim is what settles a race: `bind_owner`
/// ignores a second insert, so the loser of the race must ask again rather than
/// assume its own write won.
///
/// # Errors
/// Returns [`ApiError::Internal`] when the owner binding cannot be read or
/// written.
async fn resolve_ownership(state: &PanelState, account: &Account) -> Result<bool, ApiError> {
    if let Some(binding) = state.store.owner_binding().await? {
        return Ok(binding.matches(account));
    }
    if !state.config.matches_owner_login(&account.login) {
        return Ok(false);
    }

    state.store.bind_owner(account, Utc::now()).await?;
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

/// Every sign-in this browser has started and not yet finished.
///
/// One cookie holds them all, newest first, because a person with the panel
/// open in two tabs starts two sign-ins and both have to be able to finish.
/// A single-valued cookie meant the second tab overwrote the first, and the
/// first tab was then refused with a message nobody could act on.
#[must_use]
pub fn sign_in_states(headers: &HeaderMap) -> Vec<String> {
    cookie_value(headers, SIGN_IN_COOKIE)
        .map(|value| pending_states(&value))
        .unwrap_or_default()
}

/// The state values are URL-safe base64, whose alphabet excludes `.`, so the
/// separator can never appear inside one.
///
/// A `&str` rather than a `char` so splitting and joining can both name this
/// constant. Joining needs a string, and building one per call from a `char`
/// both allocates and leaves the separator defined in two places.
const PENDING_SEPARATOR: &str = ".";

/// Enough for the tabs a person actually keeps open, and small enough that the
/// cookie cannot be grown without bound by repeatedly hitting the start route.
pub const MAX_PENDING_SIGN_INS: usize = 4;

/// Read the pending sign-ins out of a cookie value.
///
/// Capped here as well as where the cookie is written, because the browser is
/// free to send back something the panel never wrote. Without the cap, a
/// request carrying a cookie full of separators would make every handler that
/// reads it allocate and scan a list as long as the request headers allow.
fn pending_states(value: &str) -> Vec<String> {
    value
        .split(PENDING_SEPARATOR)
        .filter(|candidate| !candidate.is_empty())
        .take(MAX_PENDING_SIGN_INS)
        .map(str::to_owned)
        .collect()
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

/// Record one more sign-in this browser has started.
///
/// Newest first, and capped, so a browser that keeps opening the start route
/// drops its oldest pending sign-in rather than growing the cookie forever.
pub fn with_pending_sign_in(
    jar: CookieJar,
    state: &PanelState,
    headers: &HeaderMap,
    value: String,
    ttl_seconds: i64,
) -> CookieJar {
    let mut pending = sign_in_states(headers);
    pending.retain(|candidate| candidate != &value);
    pending.insert(0, value);
    pending.truncate(MAX_PENDING_SIGN_INS);
    set_pending(jar, state, &pending, ttl_seconds)
}

/// Spend one pending sign-in, leaving any other tab's alone.
///
/// Clearing the whole cookie here would refuse the other tab when it came back,
/// which is the failure this list exists to prevent.
pub fn without_pending_sign_in(
    jar: CookieJar,
    state: &PanelState,
    headers: &HeaderMap,
    value: &str,
    ttl_seconds: i64,
) -> CookieJar {
    let mut pending = sign_in_states(headers);
    pending.retain(|candidate| candidate != value);
    if pending.is_empty() {
        return without_cookie(jar, state, SIGN_IN_COOKIE);
    }
    set_pending(jar, state, &pending, ttl_seconds)
}

fn set_pending(
    jar: CookieJar,
    state: &PanelState,
    pending: &[String],
    ttl_seconds: i64,
) -> CookieJar {
    jar.add(panel_cookie(
        SIGN_IN_COOKIE,
        pending.join(PENDING_SEPARATOR),
        state,
        time::Duration::seconds(ttl_seconds),
    ))
}

#[cfg(test)]
mod tests {
    use super::{MAX_PENDING_SIGN_INS, pending_states};

    #[test]
    fn a_cookie_the_panel_wrote_round_trips() {
        assert_eq!(pending_states("a.b.c"), vec!["a", "b", "c"]);
        assert!(pending_states("").is_empty());
    }

    /// The browser can return anything, so the cap has to hold on the way in
    /// and not only on the way out.
    #[test]
    fn an_oversized_cookie_is_truncated_rather_than_trusted() {
        let crafted = vec!["x"; 10_000].join(".");

        assert_eq!(pending_states(&crafted).len(), MAX_PENDING_SIGN_INS);
    }

    /// A cookie that is nothing but separators must cost nothing to read.
    #[test]
    fn empty_segments_are_dropped() {
        assert!(pending_states(&".".repeat(10_000)).is_empty());
    }
}

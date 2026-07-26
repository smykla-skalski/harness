//! Starting, finishing, and ending a sign-in.

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Redirect, Response};
use axum_extra::extract::cookie::CookieJar;
use chrono::{Duration, Utc};
use serde::Deserialize;

use super::PanelState;
use super::session::{
    has_pending_sign_in, session_token, with_pending_sign_in, with_session_cookie, without_cookie,
    without_pending_sign_in,
};
use crate::config::OAUTH_STATE_TTL_MINUTES;
use crate::error::ApiError;
use crate::store::accounts::AccountIdentity;

/// GitHub's own limit on how much of an error it will describe. Anything past
/// it is not a message a person is meant to read.
const MAX_REFLECTED_DETAIL_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
pub struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

/// Begin a sign-in.
///
/// The `state` value is recorded twice over: server-side so it can be spent
/// exactly once, and in a short-lived cookie so the callback can tell that this
/// browser is the one that started the sign-in. Without the cookie, anyone can
/// obtain a valid `state` from the panel and hand a victim's browser a finished
/// callback URL, signing them into the attacker's account.
///
/// The cookie holds every sign-in still in flight rather than only the latest,
/// so a second tab starting one does not strand the first.
///
/// # Errors
/// Returns [`ApiError::Internal`] when the sign-in cannot be recorded.
pub async fn start(State(state): State<PanelState>, jar: CookieJar) -> Result<Response, ApiError> {
    let issued = state
        .store
        .create_oauth_state(Duration::minutes(OAUTH_STATE_TTL_MINUTES), Utc::now())
        .await?;
    let redirect = state.github.authorize_url(issued.expose());
    let jar = with_pending_sign_in(
        jar,
        &state,
        issued.expose().to_owned(),
        OAUTH_STATE_TTL_MINUTES * 60,
    );

    Ok((jar, Redirect::to(&redirect)).into_response())
}

/// Finish a sign-in GitHub sent back.
///
/// # Errors
/// Returns [`ApiError::SignInFailed`] when GitHub refused, when the `state`
/// value does not belong to this browser, or when it has already been spent.
pub async fn callback(
    State(state): State<PanelState>,
    jar: CookieJar,
    headers: HeaderMap,
    Query(query): Query<CallbackQuery>,
) -> Response {
    // Whatever happens next, this browser is done with the value this callback
    // is answering for: a failed sign-in must not leave a reusable one behind.
    // Only that one is dropped, because another tab may still be waiting on
    // its own. A callback carrying no state answers for nothing, so it spends
    // nothing.
    let jar = match query.state.as_deref() {
        Some(presented) => without_pending_sign_in(jar, &state, presented),
        None => jar,
    };

    match complete_sign_in(&state, &headers, query).await {
        Ok(token) => (
            with_session_cookie(jar, &state, token),
            Redirect::to(&state.config.landing_path()),
        )
            .into_response(),
        // The cleared cookie has to ride out on the failure response too. An
        // early `?` here would drop the jar and answer without any `Set-Cookie`,
        // leaving the browser holding the value this callback just refused.
        Err(error) => (jar, error).into_response(),
    }
}

async fn complete_sign_in(
    state: &PanelState,
    headers: &HeaderMap,
    query: CallbackQuery,
) -> Result<String, ApiError> {
    let identity = finish_sign_in(state, headers, query).await?;
    issue_session(state, &identity).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn issue_session(state: &PanelState, identity: &AccountIdentity) -> Result<String, ApiError> {
    let now = Utc::now();
    let claim_owner = state.config.matches_owner_login(&identity.login);
    let (account, token) = state
        .store
        .complete_sign_in(identity, claim_owner, state.config.session_ttl, now)
        .await?;
    tracing::info!(
        login = %account.login,
        provider = %account.provider,
        "panel sign-in"
    );
    Ok(token.expose().to_owned())
}

async fn finish_sign_in(
    state: &PanelState,
    headers: &HeaderMap,
    query: CallbackQuery,
) -> Result<AccountIdentity, ApiError> {
    if let Some(presented) = query.state.as_deref() {
        validate_callback_state(state, headers, presented).await?;
    } else if query.error.is_none() {
        return Err(ApiError::SignInFailed(
            "the callback carried no state".to_owned(),
        ));
    }

    if let Some(error) = query.error.as_deref() {
        let detail = query.error_description.as_deref().unwrap_or(error);
        return Err(ApiError::SignInFailed(format!(
            "github refused the sign-in: {}",
            reflected_detail(detail)
        )));
    }

    let code = query
        .code
        .as_deref()
        .filter(|code| !code.trim().is_empty())
        .ok_or_else(|| {
            ApiError::SignInFailed("the callback carried no authorization code".to_owned())
        })?;

    let token = state
        .github
        .exchange_code(code)
        .await
        .map_err(|error| ApiError::SignInFailed(error.to_string()))?;
    state
        .github
        .fetch_identity(&token)
        .await
        .map_err(|error| ApiError::SignInFailed(error.to_string()))
}

async fn validate_callback_state(
    state: &PanelState,
    headers: &HeaderMap,
    presented: &str,
) -> Result<(), ApiError> {
    if !has_pending_sign_in(headers, presented) {
        return Err(ApiError::SignInFailed(
            "this browser did not start this sign-in, or took longer than ten minutes".to_owned(),
        ));
    }
    if !state
        .store
        .consume_oauth_state(presented, Utc::now())
        .await?
    {
        return Err(ApiError::SignInFailed(
            "this sign-in has expired or already finished".to_owned(),
        ));
    }
    Ok(())
}

/// End the session on the server, then expire the cookie.
///
/// # Errors
/// Returns [`ApiError::Forbidden`] when the request origin is absent or does
/// not exactly match the panel, and [`ApiError::Internal`] when the session
/// cannot be deleted.
pub async fn signout(
    State(state): State<PanelState>,
    jar: CookieJar,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if !origin_matches(&headers, &state.config.public_origin) {
        return Err(ApiError::Forbidden(
            "sign-out requests must come from the panel origin",
        ));
    }

    // A request that presented no session has none to end. Doing nothing also
    // avoids sending an expiry for a cookie the request did not carry.
    let Some(token) = session_token(&headers) else {
        return Ok(StatusCode::NO_CONTENT.into_response());
    };

    // Deleting server-side is what makes signing out real; expiring the cookie
    // only asks the browser to cooperate.
    state.store.delete_session(&token).await?;
    let jar = without_cookie(jar, &state, super::session::SESSION_COOKIE);
    Ok((jar, StatusCode::NO_CONTENT).into_response())
}

fn origin_matches(headers: &HeaderMap, expected: &str) -> bool {
    let mut origins = headers.get_all(header::ORIGIN).iter();
    let matches = origins
        .next()
        .and_then(|value| value.to_str().ok())
        .is_some_and(|origin| origin == expected);
    matches && origins.next().is_none()
}

/// Reduce a value GitHub echoed back to something safe to put in a response.
///
/// The callback query is whatever the requester typed, so this string is
/// caller-controlled even though it arrives labelled as GitHub's.
fn reflected_detail(detail: &str) -> String {
    let cleaned: String = detail
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_REFLECTED_DETAIL_CHARS)
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "no reason given".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::reflected_detail;

    /// A failed callback renders this string back to whoever asked for it, and
    /// the callback query is attacker-controlled.
    #[test]
    fn reflected_detail_drops_control_characters() {
        assert_eq!(
            reflected_detail("bad code\n\rSet-Cookie: x=1"),
            "bad codeSet-Cookie: x=1"
        );
    }

    #[test]
    fn reflected_detail_is_bounded() {
        assert_eq!(reflected_detail(&"a".repeat(1_000)).len(), 200);
    }

    #[test]
    fn reflected_detail_always_says_something() {
        for detail in ["", "   ", "\n\n"] {
            assert_eq!(reflected_detail(detail), "no reason given");
        }
    }
}

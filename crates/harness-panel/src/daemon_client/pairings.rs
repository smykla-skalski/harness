//! Reading and withdrawing the links the panel minted.
//!
//! Both calls carry the panel's own credential, whose `pair_manage` scope
//! reaches exactly the pairings that credential issued. The daemon does the
//! narrowing in its query, so what comes back is already the panel's and
//! nothing else; the panel never has to filter somebody else's rows out of an
//! answer it should not have received.

use reqwest::header::{ACCEPT, AUTHORIZATION, HeaderName, USER_AGENT};
use reqwest::{RequestBuilder, Response, StatusCode};
use serde::{Deserialize, Serialize};

use super::{CLIENT_ID_HEADER, DaemonClient, DaemonCredential};
use crate::error::PanelError;

/// One link the daemon issued, and what became of it.
///
/// Timestamps stay as the daemon spelled them. The panel does no arithmetic
/// with these — it neither decides expiry nor orders by them — and the browser
/// renders them against the reader's own clock, so parsing here would only add
/// a way for one unreadable field to hide a whole pairing.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct DaemonPairing {
    pub pairing_id: String,
    /// `pending`, `claimed`, `active`, `expired`, or `revoked`. Passed through
    /// rather than parsed into an enum the panel would have to keep in step:
    /// the daemon owns this vocabulary, and a state added there should reach
    /// the page as itself rather than as whatever the panel guessed.
    pub state: String,
    pub role: String,
    pub created_at: String,
    pub expires_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<DaemonPairingDevice>,
}

/// The device a claimed link became.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct DaemonPairingDevice {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
}

/// What a revoke did.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct DaemonRevoke {
    pub pairing_id: String,
    /// `device_revoked`, `link_withdrawn`, or `already_revoked`.
    pub outcome: String,
    /// When the pairing was really cut off, which for one already revoked is
    /// the earlier moment rather than the instant this request arrived.
    pub revoked_at: String,
}

#[derive(Debug, Deserialize)]
struct PairingListResponse {
    pairings: Vec<DaemonPairing>,
}

/// Why a revoke did not happen.
#[derive(Debug, thiserror::Error)]
pub enum RevokeError {
    /// The daemon will not act on this pairing for this credential. It answers
    /// the same way for a pairing another client minted and for an id that
    /// matches nothing, deliberately, so this variant asserts neither.
    #[error("no pairing with that id is available to this client")]
    NotAvailable,
    /// Anything else: the daemon refused for another reason, or could not be
    /// reached.
    #[error(transparent)]
    Failed(#[from] PanelError),
}

impl DaemonClient {
    /// Every pairing this credential is responsible for.
    ///
    /// # Errors
    /// Returns [`PanelError::Daemon`] when the daemon refuses or cannot be
    /// reached.
    pub async fn pairings(
        &self,
        credential: &DaemonCredential,
    ) -> Result<Vec<DaemonPairing>, PanelError> {
        let response = authenticated(self.http.get(self.route("/v1/remote/pairings")), credential)
            .send()
            .await
            .map_err(|error| PanelError::daemon(format!("listing pairings: {error}")))?;

        let listed: PairingListResponse = super::read_json(response, "list pairings").await?;
        Ok(listed.pairings)
    }

    /// Cut off one pairing: the device it became, or the link if unclaimed.
    ///
    /// # Errors
    /// Returns [`RevokeError::NotAvailable`] when the daemon will not act on
    /// this pairing for this credential, and [`RevokeError::Failed`] otherwise.
    pub async fn revoke_pairing(
        &self,
        credential: &DaemonCredential,
        pairing_id: &str,
    ) -> Result<DaemonRevoke, RevokeError> {
        // Percent-encoded because the id lands in a path segment. An id
        // carrying a slash would otherwise address a different route
        // altogether, and the daemon is the one that decides what its own
        // identifiers may contain.
        let path = format!(
            "/v1/remote/pairings/{}/revoke",
            utf8_percent_encode(pairing_id)
        );
        let response = authenticated(self.post(self.route(&path)), credential)
            .send()
            .await
            .map_err(|error| {
                RevokeError::Failed(PanelError::daemon(format!("revoking a pairing: {error}")))
            })?;

        read_revoke(response).await
    }
}

/// Present the panel's credential the way the daemon reads it.
fn authenticated(request: RequestBuilder, credential: &DaemonCredential) -> RequestBuilder {
    request
        .header(ACCEPT, "application/json")
        .header(
            USER_AGENT,
            concat!("harness-panel/", env!("CARGO_PKG_VERSION")),
        )
        .header(
            HeaderName::from_static(CLIENT_ID_HEADER),
            credential.client_id.clone(),
        )
        .header(AUTHORIZATION, format!("Bearer {}", credential.token))
}

async fn read_revoke(response: Response) -> Result<DaemonRevoke, RevokeError> {
    let status = response.status();
    if status.is_success() {
        return response.json().await.map_err(|error| {
            RevokeError::Failed(PanelError::daemon(format!(
                "reading the daemon answer: {error}"
            )))
        });
    }

    let detail = response.text().await.unwrap_or_default();

    // 403 and 404 are the daemon's two ways of saying the same thing to
    // different callers: it answers 403 to a credential that may not see the
    // pairing and 404 to one that may see everything. A broker credential
    // normally draws the 403, but the pairing it was cleared to revoke can also
    // go before the write lands, so both are treated alike rather than resting
    // on which one arrives.
    //
    // Only when the body says so, though. Both statuses are also answered by
    // things that have nothing to do with this pairing, and reporting one of
    // those as the pairing being unavailable is worse than saying nothing: it
    // sends somebody hunting for a permission problem while a stale credential
    // or an unserved route goes unnamed.
    let refusal = matches!(status, StatusCode::FORBIDDEN | StatusCode::NOT_FOUND);
    if refusal && names_a_pairing_refusal(&detail) {
        return Err(RevokeError::NotAvailable);
    }

    Err(RevokeError::Failed(PanelError::daemon(format!(
        "could not revoke the pairing: the daemon answered {status}: {}",
        detail.trim()
    ))))
}

/// The prefix on every error code the daemon's pairing-management routes
/// answer with.
///
/// Its authentication layer answers `REMOTE_AUTH` and a route the daemon does
/// not serve answers with no body at all, so a code carrying this prefix is
/// what distinguishes the pairing routes' own verdict from everything else
/// that arrives with the same status.
const PAIRING_ERROR_PREFIX: &str = "REMOTE_PAIRING_";

fn names_a_pairing_refusal(body: &str) -> bool {
    serde_json::from_str::<DaemonErrorEnvelope>(body)
        .is_ok_and(|envelope| envelope.error.code.starts_with(PAIRING_ERROR_PREFIX))
}

#[derive(Debug, Deserialize)]
struct DaemonErrorEnvelope {
    error: DaemonErrorBody,
}

#[derive(Debug, Deserialize)]
struct DaemonErrorBody {
    code: String,
}

/// Encode one path segment.
///
/// An allow-list rather than a list of characters to escape, so a byte nobody
/// thought of is escaped rather than passed through. The dot is escaped along
/// with everything else: a segment that survived as `..` would be normalised
/// away by URL parsing and address the route above this one.
fn utf8_percent_encode(segment: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut encoded = String::with_capacity(segment.len());
    for byte in segment.as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'~') {
            encoded.push(char::from(*byte));
        } else {
            encoded.push('%');
            encoded.push(char::from(HEX[usize::from(byte >> 4)]));
            encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::{DaemonPairing, names_a_pairing_refusal, utf8_percent_encode};

    /// The pairing routes' own refusal is the only thing that may read as one.
    /// A stale credential and a route the daemon does not serve arrive with the
    /// same statuses, and calling either of those "no such pairing" hides a
    /// fault an operator has to fix.
    #[test]
    fn only_the_pairing_routes_own_refusal_reads_as_one() {
        assert!(names_a_pairing_refusal(
            r#"{"error":{"code":"REMOTE_PAIRING_NOT_AVAILABLE","message":"no"}}"#
        ));
        assert!(names_a_pairing_refusal(
            r#"{"error":{"code":"REMOTE_PAIRING_NOT_FOUND","message":"no"}}"#
        ));

        assert!(
            !names_a_pairing_refusal(r#"{"error":{"code":"REMOTE_AUTH","message":"scope"}}"#),
            "a credential the daemon will not accept is not a missing pairing"
        );
        assert!(
            !names_a_pairing_refusal(""),
            "a route the daemon does not serve answers with no body at all"
        );
        assert!(
            !names_a_pairing_refusal("<html>404</html>"),
            "a proxy between the two answers with whatever it likes"
        );
    }

    /// The daemon grows fields the panel does not read, and a strict decode
    /// would turn each addition into an outage on a panel that had no need of
    /// it. Only the fields the page renders are named here.
    #[test]
    fn a_pairing_decodes_without_the_fields_the_panel_ignores() {
        let entry: DaemonPairing = serde_json::from_value(serde_json::json!({
            "pairing_id": "pair-1",
            "state": "active",
            "role": "operator",
            "created_at": "2026-07-26T10:00:00Z",
            "expires_at": "2026-07-26T10:10:00Z",
            "claimed_at": "2026-07-26T10:01:00Z",
            "minted_for": {"provider": "github", "subject_id": "4242", "display_name": "Ada"},
            "minted_by": "panel-client",
            "device": {
                "client_id": "device-1",
                "display_name": "Ada's laptop",
                "platform": "macos",
                "last_seen_at": "2026-07-26T10:05:00Z"
            },
            "something_the_daemon_added_later": true
        }))
        .expect("a pairing the panel can read");

        assert_eq!(entry.state, "active");
        assert_eq!(
            entry.device.expect("a claimed pairing names its device").platform,
            "macos"
        );
        assert!(entry.revoked_at.is_none());
    }

    /// A pending link has no device and no claim, and those absences are how
    /// the page tells it from a claimed one.
    #[test]
    fn a_pending_pairing_needs_neither_a_device_nor_a_claim() {
        let entry: DaemonPairing = serde_json::from_value(serde_json::json!({
            "pairing_id": "pair-2",
            "state": "pending",
            "role": "operator",
            "created_at": "2026-07-26T10:00:00Z",
            "expires_at": "2026-07-26T10:10:00Z"
        }))
        .expect("a pending pairing");

        assert!(entry.claimed_at.is_none());
        assert!(entry.device.is_none());
    }

    /// The id becomes a path segment. A slash in one would address a different
    /// route, a bare `..` would climb out of this one, and a space or a control
    /// character would not survive the request line at all.
    #[test]
    fn an_id_is_escaped_into_one_path_segment() {
        assert_eq!(utf8_percent_encode("pair-1_a~b"), "pair-1_a~b");
        assert_eq!(utf8_percent_encode(".."), "%2E%2E");
        assert_eq!(
            utf8_percent_encode("../v1/remote/clients"),
            "%2E%2E%2Fv1%2Fremote%2Fclients"
        );
        assert_eq!(utf8_percent_encode("a b"), "a%20b");
        assert_eq!(utf8_percent_encode("é"), "%C3%A9");
    }
}

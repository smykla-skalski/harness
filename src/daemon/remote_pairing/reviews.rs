use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::expand_client_scopes;
use crate::reviews::ReviewsQueryRequest;

use super::{RemotePairingCodeHash, RemotePairingError, RemotePairingRecord};

impl RemotePairingRecord {
    /// Build a pairing record carrying an optional server-owned Reviews query.
    ///
    /// # Errors
    /// Returns [`RemotePairingError`] when pairing identity, scopes, or the
    /// Reviews query is invalid.
    pub fn new_with_reviews_query(
        pairing_id: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        code: &str,
        created_at: impl Into<String>,
        expires_at: impl Into<String>,
        reviews_query: Option<&ReviewsQueryRequest>,
    ) -> Result<Self, RemotePairingError> {
        let pairing_id = pairing_id.into();
        if pairing_id.trim().is_empty() {
            return Err(RemotePairingError::EmptyPairingId);
        }
        Ok(Self {
            pairing_id,
            code_hash: RemotePairingCodeHash::from_code(code)?,
            role,
            scopes: expand_client_scopes(role, requested_scopes)?,
            created_at: created_at.into(),
            expires_at: expires_at.into(),
            reviews_query: reviews_query
                .map(normalize_remote_reviews_query)
                .transpose()?,
        })
    }

    #[cfg(test)]
    pub fn new_with_reviews_query_for_tests(
        pairing_id: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        code: &str,
        created_at: impl Into<String>,
        expires_at: impl Into<String>,
        reviews_query: Option<ReviewsQueryRequest>,
    ) -> Result<Self, RemotePairingError> {
        Self::new_with_reviews_query(
            pairing_id,
            role,
            requested_scopes,
            code,
            created_at,
            expires_at,
            reviews_query.as_ref(),
        )
    }
}

pub(crate) fn normalize_remote_reviews_query(
    query: &ReviewsQueryRequest,
) -> Result<ReviewsQueryRequest, RemotePairingError> {
    let normalized = ReviewsQueryRequest {
        authors: query.normalized_authors(),
        organizations: query.normalized_organizations(),
        repositories: query.normalized_repositories(),
        exclude_repositories: query.normalized_exclude_repositories(),
        force_refresh: false,
        cache_max_age_seconds: query.cache_max_age_seconds(),
        backport_detection_enabled: query.backport_detection_enabled,
        backport_patterns: query.normalized_backport_patterns(),
    };
    normalized
        .validate()
        .map_err(|error| RemotePairingError::InvalidReviewsQuery(error.to_string()))?;
    Ok(normalized)
}

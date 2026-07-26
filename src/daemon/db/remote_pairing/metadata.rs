use serde::{Deserialize, Serialize};

use crate::daemon::db::{CliError, db_error};
use crate::daemon::remote_pairing::{RemotePairingSubject, normalize_remote_reviews_query};
use crate::reviews::ReviewsQueryRequest;

#[derive(Default, Deserialize, Serialize)]
struct RemotePairingMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reviews_query: Option<ReviewsQueryRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    minted_for: Option<RemotePairingSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    minted_by: Option<String>,
    /// Set when a link is revoked before anyone claimed it. A claimed link is
    /// revoked by cutting off the client it became, which the clients table
    /// records; this covers the case where there is no client yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    revoked_at: Option<String>,
}

/// What the metadata column carries beyond the columns of its own.
#[derive(Debug)]
pub(super) struct RemotePairingMetadataFields {
    pub reviews_query: Option<ReviewsQueryRequest>,
    pub minted_for: Option<RemotePairingSubject>,
    pub minted_by: Option<String>,
    pub revoked_at: Option<String>,
}

pub(super) fn encode_remote_pairing_metadata(
    reviews_query: Option<&ReviewsQueryRequest>,
    minted_for: Option<&RemotePairingSubject>,
    minted_by: Option<&str>,
    revoked_at: Option<&str>,
) -> Result<String, CliError> {
    serde_json::to_string(&RemotePairingMetadata {
        reviews_query: reviews_query.cloned(),
        minted_for: minted_for.cloned(),
        minted_by: minted_by.map(str::to_owned),
        revoked_at: revoked_at.map(str::to_owned),
    })
    .map_err(|error| db_error(format!("serialize remote pairing metadata: {error}")))
}

pub(super) fn decode_remote_pairing_metadata(
    value: &str,
) -> Result<RemotePairingMetadataFields, String> {
    let metadata = serde_json::from_str::<RemotePairingMetadata>(value)
        .map_err(|error| format!("parse remote pairing metadata: {error}"))?;
    let reviews_query = metadata
        .reviews_query
        .as_ref()
        .map(normalize_remote_reviews_query)
        .transpose()
        .map_err(|error| error.to_string())?;
    // A subject that fails validation on the way out means the row was written
    // by something that bypassed the mint path, so refuse it rather than let a
    // bogus identity ride along into the audit trail.
    if let Some(subject) = metadata.minted_for.as_ref() {
        subject.validate().map_err(|error| error.to_string())?;
    }
    Ok(RemotePairingMetadataFields {
        reviews_query,
        minted_for: metadata.minted_for,
        minted_by: metadata.minted_by,
        revoked_at: metadata.revoked_at,
    })
}

#[cfg(test)]
mod tests {
    use super::{decode_remote_pairing_metadata, encode_remote_pairing_metadata};
    use crate::daemon::remote_pairing::RemotePairingSubject;

    #[test]
    fn invalid_reviews_query_metadata_is_rejected() {
        let error =
            decode_remote_pairing_metadata(r#"{"reviews_query":{"authors":["renovate[bot]"]}}"#)
                .expect_err("unscoped Reviews query must fail");

        assert!(error.contains("organization or repository"));
    }

    #[test]
    fn minted_for_survives_a_round_trip() {
        let subject =
            RemotePairingSubject::new("github", "4242", "Ada Lovelace").expect("valid subject");

        let encoded =
            encode_remote_pairing_metadata(None, Some(&subject), Some("panel-1"), None)
                .expect("encode");
        let decoded = decode_remote_pairing_metadata(&encoded).expect("decode");

        assert_eq!(decoded.minted_for, Some(subject));
        assert!(decoded.reviews_query.is_none());
    }

    /// Rows written before minting existed carry no `minted_for` key at all.
    #[test]
    fn metadata_without_a_subject_decodes_as_absent() {
        let decoded = decode_remote_pairing_metadata("{}").expect("decode legacy metadata");

        assert!(decoded.minted_for.is_none());
        assert!(decoded.reviews_query.is_none());
    }

    #[test]
    fn a_stored_subject_that_fails_validation_is_rejected() {
        let error = decode_remote_pairing_metadata(
            r#"{"minted_for":{"provider":"github","subject_id":"","display_name":"Ada"}}"#,
        )
        .expect_err("blank subject id must fail");

        assert!(error.contains("subject_id"), "{error}");
    }
}

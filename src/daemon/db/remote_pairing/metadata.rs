use serde::{Deserialize, Serialize};

use crate::daemon::db::{CliError, db_error};
use crate::daemon::remote_pairing::normalize_remote_reviews_query;
use crate::reviews::ReviewsQueryRequest;

#[derive(Default, Deserialize, Serialize)]
struct RemotePairingMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reviews_query: Option<ReviewsQueryRequest>,
}

pub(super) fn encode_remote_pairing_metadata(
    reviews_query: Option<&ReviewsQueryRequest>,
) -> Result<String, CliError> {
    serde_json::to_string(&RemotePairingMetadata {
        reviews_query: reviews_query.cloned(),
    })
    .map_err(|error| db_error(format!("serialize remote pairing metadata: {error}")))
}

pub(super) fn decode_remote_pairing_metadata(
    value: &str,
) -> Result<Option<ReviewsQueryRequest>, String> {
    serde_json::from_str::<RemotePairingMetadata>(value)
        .map(|metadata| metadata.reviews_query)
        .map_err(|error| format!("parse remote pairing metadata: {error}"))
        .and_then(|query| {
            query
                .as_ref()
                .map(normalize_remote_reviews_query)
                .transpose()
                .map_err(|error| error.to_string())
        })
}

#[cfg(test)]
mod tests {
    use super::decode_remote_pairing_metadata;

    #[test]
    fn invalid_reviews_query_metadata_is_rejected() {
        let error =
            decode_remote_pairing_metadata(r#"{"reviews_query":{"authors":["renovate[bot]"]}}"#)
                .expect_err("unscoped Reviews query must fail");

        assert!(error.contains("organization or repository"));
    }
}

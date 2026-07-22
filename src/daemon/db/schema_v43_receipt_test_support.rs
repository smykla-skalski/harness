use sha2::{Digest, Sha256};

use crate::daemon::task_board_remote_transport::wire::{
    RemoteClaimRequest, RemoteClaimResponse, RemoteLease, RemoteOfferRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

const CLAIM_RECEIPT_DOMAIN: &str = "harness.task-board.remote-claim-receipt.v1";
const PRINCIPAL: &str = "executor:executor-a";

pub(super) struct StrictClaimReceipt {
    pub(super) request_sha256: String,
    pub(super) response_json: String,
    pub(super) receipt_sha256: String,
}

pub(super) fn strict_claim_receipt(
    request_json: &str,
    assignment_id: &str,
    epoch: u64,
    lease_id: &str,
    claimed_at: &str,
) -> StrictClaimReceipt {
    let offer: RemoteOfferRequest =
        serde_json::from_str(request_json).expect("decode strict offer request");
    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal strict claim request");
    let response = RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding,
        offer_request_sha256: offer.request_sha256,
        lease: RemoteLease {
            lease_id: lease_id.into(),
            expires_at: "2026-07-19T09:05:00Z".into(),
        },
        claimed_at: claimed_at.into(),
    };
    response
        .validate(&claim)
        .expect("validate strict claim response");
    let response_json = serde_json::to_string(&response).expect("encode strict claim response");
    let receipt_sha256 = receipt_digest(
        assignment_id,
        epoch,
        PRINCIPAL,
        &claim.request_sha256,
        &response_json,
    );
    StrictClaimReceipt {
        request_sha256: claim.request_sha256,
        response_json,
        receipt_sha256,
    }
}

fn receipt_digest(
    assignment_id: &str,
    epoch: u64,
    principal: &str,
    request_sha256: &str,
    response_json: &str,
) -> String {
    let mut hasher = Sha256::new();
    let epoch = epoch.to_string();
    for value in [
        CLAIM_RECEIPT_DOMAIN,
        assignment_id,
        &epoch,
        principal,
        request_sha256,
        response_json,
    ] {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    hex::encode(hasher.finalize())
}

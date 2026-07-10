use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::Serialize;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote_acme::build_remote_acme_runtime_plan;
use crate::errors::{CliError, CliErrorKind};

pub(super) struct RemotePairingInvitation {
    pub(super) endpoint: String,
    pub(super) server_spki_sha256: String,
    pub(super) pairing_url: String,
}

#[derive(Serialize)]
struct RemotePairingInvitationPayload<'a> {
    version: u8,
    endpoint: &'a str,
    code: &'a str,
    server_spki_sha256: &'a str,
    role: &'a str,
    scopes: &'a [String],
    expires_at: &'a str,
}

pub(super) fn build_remote_pairing_invitation(
    db: &DaemonDb,
    code: &str,
    role: &str,
    scopes: &[String],
    expires_at: &str,
) -> Result<RemotePairingInvitation, CliError> {
    let state = db.load_remote_acme_state()?;
    let serve_config = state
        .serve_config
        .as_ref()
        .ok_or_else(|| remote_pairing_identity_error("persisted remote serve config is missing"))?;
    let runtime_state = db.load_remote_acme_runtime_state()?;
    let runtime_plan = build_remote_acme_runtime_plan(serve_config, &runtime_state)
        .map_err(|error| remote_pairing_identity_error(error.to_string()))?;
    let endpoint = runtime_plan.public_https_origin();
    let server_spki_sha256 = runtime_plan
        .certificate()
        .spki_sha256_pin()
        .map_err(|error| remote_pairing_identity_error(error.to_string()))?;
    let payload = RemotePairingInvitationPayload {
        version: 1,
        endpoint: endpoint.as_str(),
        code,
        server_spki_sha256: server_spki_sha256.as_str(),
        role,
        scopes,
        expires_at,
    };
    let payload = serde_json::to_vec(&payload).map_err(|error| {
        CliErrorKind::workflow_parse(format!("encode remote pairing invitation: {error}"))
    })?;
    let pairing_url = format!(
        "harness://remote-pair?payload={}",
        URL_SAFE_NO_PAD.encode(payload)
    );
    Ok(RemotePairingInvitation {
        endpoint,
        server_spki_sha256,
        pairing_url,
    })
}

fn remote_pairing_identity_error(detail: impl AsRef<str>) -> CliError {
    CliErrorKind::workflow_parse(format!(
        "remote pairing requires a persisted remote TLS identity: {}",
        detail.as_ref()
    ))
    .into()
}

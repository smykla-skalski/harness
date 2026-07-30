pub use harness_remote_trust::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteBearerToken,
    RemoteClientRegistration, RemoteIdentityError, RemoteStoredAuditEvent, RemoteStoredClient,
    RemoteTokenHash, expand_client_scopes, parse_remote_role, parse_remote_scope,
};
pub(crate) use harness_remote_trust::remote_identity::{
    bounded_remote_request_id, redact_remote_error_detail, remote_token_hint,
};

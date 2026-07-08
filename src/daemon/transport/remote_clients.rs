use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteBearerToken,
    RemoteStoredClient, remote_token_hint,
};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::control::{adopt_daemon_root_for_transport_command, print_json};
use super::remote::{DaemonRemoteClientIdArgs, DaemonRemoteClientsCommand, open_remote_daemon_db};

impl Execute for DaemonRemoteClientsCommand {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-remote-clients");
        let db = open_remote_daemon_db()?;
        let now = utc_now();
        let audit_event_id = format!("remote-clients-{}-{}", self.action_label(), Uuid::new_v4());
        match self {
            Self::List => {
                let response =
                    self.list_clients_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
            }
            Self::Revoke(args) => {
                let response =
                    args.revoke_client_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
            }
            Self::Rotate(args) => {
                let token = RemoteBearerToken::generate();
                let response = args.rotate_client_with(
                    &db,
                    token.expose(),
                    audit_event_id.as_str(),
                    now.as_str(),
                )?;
                print_json(&response)?;
            }
        }
        Ok(0)
    }
}

impl DaemonRemoteClientsCommand {
    /// List paired remote clients without exposing token hashes or raw tokens.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads or audit writes fail.
    pub(crate) fn list_clients_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
    ) -> Result<DaemonRemoteClientsListResponse, CliError> {
        let Self::List = self else {
            return Err(CliErrorKind::workflow_parse("remote clients command must be list").into());
        };
        let clients = db
            .list_remote_clients()?
            .iter()
            .map(DaemonRemoteClientSummary::from_stored_client)
            .collect();
        record_remote_clients_audit(
            db,
            audit_event_id,
            now,
            None,
            "remote.clients.list",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientsListResponse { clients })
    }

    #[must_use]
    const fn action_label(&self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Revoke(_) => "revoke",
            Self::Rotate(_) => "rotate",
        }
    }
}

impl DaemonRemoteClientIdArgs {
    /// Revoke a paired remote client.
    ///
    /// # Errors
    /// Returns [`CliError`] when the client is unknown, already revoked, or
    /// persistence/audit fails.
    pub(crate) fn revoke_client_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        revoked_at: &str,
    ) -> Result<DaemonRemoteClientRevokeResponse, CliError> {
        let client_id = self.trimmed_client_id()?;
        let changed = db.revoke_remote_client(client_id, revoked_at)?;
        if !changed {
            record_remote_clients_audit(
                db,
                audit_event_id,
                revoked_at,
                Some(client_id),
                "remote.clients.revoke",
                RemoteAuditOutcome::Failure,
                Some("remote client not found or already revoked"),
            )?;
            return Err(CliErrorKind::workflow_parse(format!(
                "remote client '{client_id}' not found or already revoked"
            ))
            .into());
        }
        record_remote_clients_audit(
            db,
            audit_event_id,
            revoked_at,
            Some(client_id),
            "remote.clients.revoke",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientRevokeResponse {
            client_id: client_id.to_string(),
            revoked_at: revoked_at.to_string(),
        })
    }

    /// Rotate a paired remote client's bearer token.
    ///
    /// # Errors
    /// Returns [`CliError`] when the client is unknown, revoked, the new token
    /// is invalid, or persistence/audit fails.
    pub(crate) fn rotate_client_with(
        &self,
        db: &DaemonDb,
        token: &str,
        audit_event_id: &str,
        rotated_at: &str,
    ) -> Result<DaemonRemoteClientRotateResponse, CliError> {
        let client_id = self.trimmed_client_id()?;
        let changed = db.rotate_remote_client_token(client_id, token, rotated_at)?;
        if !changed {
            record_remote_clients_audit(
                db,
                audit_event_id,
                rotated_at,
                Some(client_id),
                "remote.clients.rotate",
                RemoteAuditOutcome::Failure,
                Some("remote client not found or revoked"),
            )?;
            return Err(CliErrorKind::workflow_parse(format!(
                "remote client '{client_id}' not found or revoked"
            ))
            .into());
        }
        record_remote_clients_audit(
            db,
            audit_event_id,
            rotated_at,
            Some(client_id),
            "remote.clients.rotate",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientRotateResponse {
            client_id: client_id.to_string(),
            token: token.to_string(),
            token_hint: remote_token_hint(token),
            rotated_at: rotated_at.to_string(),
        })
    }

    fn trimmed_client_id(&self) -> Result<&str, CliError> {
        let client_id = self.client_id.trim();
        if client_id.is_empty() {
            return Err(CliErrorKind::workflow_parse("remote client id is required").into());
        }
        Ok(client_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientsListResponse {
    pub clients: Vec<DaemonRemoteClientSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientSummary {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    pub role: String,
    pub scopes: Vec<String>,
    pub token_hint: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub rotated_at: Option<String>,
}

impl DaemonRemoteClientSummary {
    fn from_stored_client(client: &RemoteStoredClient) -> Self {
        Self {
            client_id: client.client_id.clone(),
            display_name: client.display_name.clone(),
            platform: client.platform.clone(),
            role: client.role.as_str().to_string(),
            scopes: client
                .scopes
                .iter()
                .map(|scope| scope.as_str().to_string())
                .collect(),
            token_hint: client.token_hint.clone(),
            created_at: client.created_at.clone(),
            last_seen_at: client.last_seen_at.clone(),
            revoked_at: client.revoked_at.clone(),
            rotated_at: client.rotated_at.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientRevokeResponse {
    pub client_id: String,
    pub revoked_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientRotateResponse {
    pub client_id: String,
    pub token: String,
    pub token_hint: String,
    pub rotated_at: String,
}

fn record_remote_clients_audit(
    db: &DaemonDb,
    event_id: &str,
    recorded_at: &str,
    client_id: Option<&str>,
    route_or_method: &str,
    outcome: RemoteAuditOutcome,
    error_detail: Option<&str>,
) -> Result<(), CliError> {
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        event_id,
        recorded_at,
        None,
        client_id,
        route_or_method,
        RemoteAccessScope::Admin,
        RemoteAuditScopeDecision::Allowed,
        outcome,
        None,
        error_detail,
    ))
}

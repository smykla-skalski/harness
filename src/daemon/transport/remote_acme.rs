use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::{DaemonDb, RemoteAcmeStoredState};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::control::{adopt_daemon_root_for_transport_command, print_json};
use super::remote::{DaemonRemoteAcmeCommand, open_remote_daemon_db};

impl Execute for DaemonRemoteAcmeCommand {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-remote-acme");
        let db = open_remote_daemon_db()?;
        let now = utc_now();
        let audit_event_id = format!("remote-acme-{}-{}", self.action_label(), Uuid::new_v4());
        match self {
            Self::Status => {
                let response = self.status_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
            }
            Self::Renew => {
                let response = self.renew_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
                response.ensure_success()?;
            }
        }
        Ok(0)
    }
}

impl DaemonRemoteAcmeCommand {
    /// Return token-safe ACME state and audit the status read.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads or audit writes fail.
    pub(crate) fn status_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
    ) -> Result<DaemonRemoteAcmeStatusResponse, CliError> {
        let Self::Status = self else {
            return Err(CliErrorKind::workflow_parse("remote acme command must be status").into());
        };
        let state = db.load_remote_acme_state()?;
        record_remote_acme_audit(
            db,
            audit_event_id,
            now,
            "remote.acme.status",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteAcmeStatusResponse::from_state(&state))
    }

    /// Record the current renewal failure reason until real ACME issuance lands.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads, writes, or audit writes fail.
    pub(crate) fn renew_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
    ) -> Result<DaemonRemoteAcmeRenewResponse, CliError> {
        let Self::Renew = self else {
            return Err(CliErrorKind::workflow_parse("remote acme command must be renew").into());
        };
        let state = db.load_remote_acme_state()?;
        let detail = renewal_failure_detail(&state);
        db.record_remote_acme_renewal_failure(detail, now)?;
        let state = db.load_remote_acme_state()?;
        record_remote_acme_audit(
            db,
            audit_event_id,
            now,
            "remote.acme.renew",
            RemoteAuditOutcome::Failure,
            state.renewal_error.as_deref(),
        )?;
        Ok(DaemonRemoteAcmeRenewResponse::from_state(&state))
    }

    #[must_use]
    const fn action_label(&self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Renew => "renew",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteAcmeStatusResponse {
    pub account_configured: bool,
    pub account_id: Option<String>,
    pub certificate_configured: bool,
    pub certificate_fingerprint: Option<String>,
    pub renewal_status: String,
    pub renewal_error: Option<String>,
    pub updated_at: String,
}

impl DaemonRemoteAcmeStatusResponse {
    fn from_state(state: &RemoteAcmeStoredState) -> Self {
        Self {
            account_configured: state.account_configured,
            account_id: state.account_id.clone(),
            certificate_configured: state.certificate_configured,
            certificate_fingerprint: state.certificate_fingerprint.clone(),
            renewal_status: state.renewal_status.as_str().to_string(),
            renewal_error: state.renewal_error.clone(),
            updated_at: state.updated_at.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteAcmeRenewResponse {
    pub account_configured: bool,
    pub certificate_configured: bool,
    pub certificate_fingerprint: Option<String>,
    pub renewal_status: String,
    pub renewal_error: Option<String>,
    pub updated_at: String,
}

impl DaemonRemoteAcmeRenewResponse {
    fn from_state(state: &RemoteAcmeStoredState) -> Self {
        Self {
            account_configured: state.account_configured,
            certificate_configured: state.certificate_configured,
            certificate_fingerprint: state.certificate_fingerprint.clone(),
            renewal_status: state.renewal_status.as_str().to_string(),
            renewal_error: state.renewal_error.clone(),
            updated_at: state.updated_at.clone(),
        }
    }

    /// Return an error for renewal attempts that recorded a failure state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the renewal status is not successful.
    pub(crate) fn ensure_success(&self) -> Result<(), CliError> {
        if self.renewal_status == "succeeded" {
            return Ok(());
        }
        let detail = self
            .renewal_error
            .as_deref()
            .unwrap_or("remote ACME renewal did not succeed");
        Err(CliErrorKind::workflow_parse(format!(
            "remote ACME renewal did not succeed: {detail}"
        ))
        .into())
    }
}

fn renewal_failure_detail(state: &RemoteAcmeStoredState) -> &'static str {
    if !state.account_configured {
        "remote daemon requires persisted ACME state"
    } else if !state.certificate_configured {
        "remote daemon requires a persisted TLS certificate"
    } else {
        "remote ACME renewal client is not implemented"
    }
}

fn record_remote_acme_audit(
    db: &DaemonDb,
    event_id: &str,
    recorded_at: &str,
    route_or_method: &str,
    outcome: RemoteAuditOutcome,
    error_detail: Option<&str>,
) -> Result<(), CliError> {
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        event_id,
        recorded_at,
        None,
        None,
        route_or_method,
        RemoteAccessScope::Admin,
        RemoteAuditScopeDecision::Allowed,
        outcome,
        None,
        error_detail,
    ))
}

use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::{DaemonDb, RemoteAcmeStoredState};
use crate::daemon::remote::{RemoteAccessScope, RemoteDaemonServeConfig};
use crate::daemon::remote_acme::{
    RemoteAcmeIssuanceState, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
};
use crate::daemon::remote_acme_issuer::SystemRemoteAcmeIssuer;
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

    /// Issue or renew the remote daemon certificate through the production ACME client.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads, writes, or audit writes fail.
    pub(crate) fn renew_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
    ) -> Result<DaemonRemoteAcmeRenewResponse, CliError> {
        self.renew_with_issuer(db, audit_event_id, now, &SystemRemoteAcmeIssuer)
    }

    /// Renew the remote certificate through the supplied issuer and persist the
    /// token-safe result for status/serve consumers.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads/writes or audit writes fail.
    pub(crate) fn renew_with_issuer<I>(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
        issuer: &I,
    ) -> Result<DaemonRemoteAcmeRenewResponse, CliError>
    where
        I: RemoteAcmeRenewalIssuer,
    {
        let Self::Renew = self else {
            return Err(CliErrorKind::workflow_parse("remote acme command must be renew").into());
        };
        let state = db.load_remote_acme_state()?;
        let issuance = db.load_remote_acme_issuance_state()?;
        let outcome = renew_remote_acme_certificate(
            db,
            &state,
            &issuance,
            state.serve_config.as_ref(),
            issuer,
            now,
        )?;
        let state = db.load_remote_acme_state()?;
        record_remote_acme_audit(
            db,
            audit_event_id,
            now,
            "remote.acme.renew",
            outcome,
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
    pub domain: Option<String>,
    pub host: Option<String>,
    pub https_port: Option<u16>,
    pub http_port: Option<u16>,
    pub acme_email: Option<String>,
    pub acme_challenge: Option<String>,
    pub acme_dns_provider: Option<String>,
    pub certificate_configured: bool,
    pub certificate_fingerprint: Option<String>,
    pub renewal_status: String,
    pub renewal_error: Option<String>,
    pub updated_at: String,
}

impl DaemonRemoteAcmeStatusResponse {
    fn from_state(state: &RemoteAcmeStoredState) -> Self {
        let serve_config = state.serve_config.as_ref();
        Self {
            account_configured: state.account_configured,
            account_id: state.account_id.clone(),
            domain: serve_config.map(|config| config.domain.clone()),
            host: serve_config.map(|config| config.host.clone()),
            https_port: serve_config.map(|config| config.https_port),
            http_port: serve_config.map(|config| config.http_port),
            acme_email: serve_config.map(|config| config.acme_email.clone()),
            acme_challenge: serve_config.map(|config| config.acme_challenge.as_str().to_string()),
            acme_dns_provider: serve_config
                .and_then(|config| config.acme_dns_provider)
                .map(|provider| provider.as_str().to_string()),
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
            .unwrap_or("remote ACME renewal failed");
        Err(CliErrorKind::workflow_parse(detail.to_string()).into())
    }
}

fn missing_serve_config_failure_detail() -> &'static str {
    "remote daemon requires persisted remote ACME serve config"
}

fn renew_remote_acme_certificate<I>(
    db: &DaemonDb,
    state: &RemoteAcmeStoredState,
    issuance: &RemoteAcmeIssuanceState,
    serve_config: Option<&RemoteDaemonServeConfig>,
    issuer: &I,
    now: &str,
) -> Result<RemoteAuditOutcome, CliError>
where
    I: RemoteAcmeRenewalIssuer,
{
    let Some(serve_config) = serve_config else {
        db.record_remote_acme_renewal_failure(missing_serve_config_failure_detail(), now)?;
        return Ok(RemoteAuditOutcome::Failure);
    };
    let account = match issuance.account.as_ref() {
        Some(account) => account.clone(),
        None => match issuer.create_account(serve_config) {
            Ok(account) => {
                db.record_remote_acme_account(&account, now)?;
                account
            }
            Err(detail) => {
                db.record_remote_acme_renewal_failure(&detail, now)?;
                return Ok(RemoteAuditOutcome::Failure);
            }
        },
    };
    let request = RemoteAcmeRenewalRequest::new(
        &account,
        state.certificate_fingerprint.as_deref(),
        issuance.previous_private_key_pem.as_deref(),
        serve_config,
    );
    match issuer.renew_certificate(&request) {
        Ok(bundle) => {
            db.record_remote_acme_renewal_success(&bundle, now)?;
            Ok(RemoteAuditOutcome::Success)
        }
        Err(detail) => {
            db.record_remote_acme_renewal_failure(&detail, now)?;
            Ok(RemoteAuditOutcome::Failure)
        }
    }
}

pub(super) fn record_remote_acme_audit(
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

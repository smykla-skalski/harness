use serde::Serialize;
use uuid::Uuid;

use crate::daemon::db::{DaemonDb, RemoteAcmeStoredState};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteStoredClient,
};
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::control::{adopt_daemon_root_for_transport_command, print_json};
use super::remote::open_remote_daemon_db;

pub(super) fn execute_remote_doctor() -> Result<i32, CliError> {
    adopt_daemon_root_for_transport_command("daemon-remote-doctor");
    let db = open_remote_daemon_db()?;
    let audit_event_id = format!("remote-doctor-{}", Uuid::new_v4());
    let now = utc_now();
    let response = run_remote_doctor_with(&db, audit_event_id.as_str(), now.as_str())?;
    print_json(&response)?;
    Ok(0)
}

/// Build a read-only remote daemon readiness diagnostic report.
///
/// # Errors
/// Returns [`CliError`] when remote ACME/client state or audit persistence
/// cannot be read or written.
pub(crate) fn run_remote_doctor_with(
    db: &DaemonDb,
    audit_event_id: &str,
    now: &str,
) -> Result<DaemonRemoteDoctorResponse, CliError> {
    let acme = db.load_remote_acme_state()?;
    let clients = db.list_remote_clients()?;
    let summary = DaemonRemoteDoctorSummary::from_state(&acme, &clients);
    let checks = remote_doctor_checks(&summary);
    let status = if checks.iter().any(DaemonRemoteDoctorCheck::failed) {
        "not_ready"
    } else {
        "ready"
    };
    record_remote_doctor_audit(db, audit_event_id, now, RemoteAuditOutcome::Success)?;
    Ok(DaemonRemoteDoctorResponse {
        status: status.to_string(),
        checks,
        summary,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteDoctorResponse {
    pub status: String,
    pub checks: Vec<DaemonRemoteDoctorCheck>,
    pub summary: DaemonRemoteDoctorSummary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteDoctorCheck {
    pub name: String,
    pub status: String,
    pub detail: String,
}

impl DaemonRemoteDoctorCheck {
    fn pass(name: &str, detail: impl Into<String>) -> Self {
        Self::new(name, "pass", detail)
    }

    fn warn(name: &str, detail: impl Into<String>) -> Self {
        Self::new(name, "warn", detail)
    }

    fn fail(name: &str, detail: impl Into<String>) -> Self {
        Self::new(name, "fail", detail)
    }

    fn new(name: &str, status: &str, detail: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status: status.to_string(),
            detail: detail.into(),
        }
    }

    fn failed(&self) -> bool {
        self.status == "fail"
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteDoctorSummary {
    pub acme_account_configured: bool,
    pub certificate_configured: bool,
    pub certificate_fingerprint: Option<String>,
    pub renewal_status: String,
    pub renewal_error: Option<String>,
    pub updated_at: String,
    pub active_client_count: usize,
    pub revoked_client_count: usize,
}

impl DaemonRemoteDoctorSummary {
    fn from_state(acme: &RemoteAcmeStoredState, clients: &[RemoteStoredClient]) -> Self {
        Self {
            acme_account_configured: acme.account_configured,
            certificate_configured: acme.certificate_configured,
            certificate_fingerprint: acme.certificate_fingerprint.clone(),
            renewal_status: acme.renewal_status.as_str().to_string(),
            renewal_error: acme.renewal_error.clone(),
            updated_at: acme.updated_at.clone(),
            active_client_count: clients
                .iter()
                .filter(|client| client.revoked_at.is_none())
                .count(),
            revoked_client_count: clients
                .iter()
                .filter(|client| client.revoked_at.is_some())
                .count(),
        }
    }
}

fn remote_doctor_checks(summary: &DaemonRemoteDoctorSummary) -> Vec<DaemonRemoteDoctorCheck> {
    vec![
        acme_account_check(summary),
        tls_certificate_check(summary),
        acme_renewal_check(summary),
        remote_clients_check(summary),
    ]
}

fn acme_account_check(summary: &DaemonRemoteDoctorSummary) -> DaemonRemoteDoctorCheck {
    if summary.acme_account_configured {
        DaemonRemoteDoctorCheck::pass("acme_account", "persisted ACME account configured")
    } else {
        DaemonRemoteDoctorCheck::fail("acme_account", "missing persisted ACME account")
    }
}

fn tls_certificate_check(summary: &DaemonRemoteDoctorSummary) -> DaemonRemoteDoctorCheck {
    if summary.certificate_configured {
        DaemonRemoteDoctorCheck::pass("tls_certificate", "persisted TLS certificate configured")
    } else {
        DaemonRemoteDoctorCheck::fail("tls_certificate", "missing persisted TLS certificate")
    }
}

fn acme_renewal_check(summary: &DaemonRemoteDoctorSummary) -> DaemonRemoteDoctorCheck {
    match summary.renewal_status.as_str() {
        "succeeded" => DaemonRemoteDoctorCheck::pass("acme_renewal", "renewal succeeded"),
        "failed" => DaemonRemoteDoctorCheck::fail(
            "acme_renewal",
            summary
                .renewal_error
                .as_deref()
                .unwrap_or("remote ACME renewal failed"),
        ),
        _ => DaemonRemoteDoctorCheck::warn("acme_renewal", "no renewal result recorded"),
    }
}

fn remote_clients_check(summary: &DaemonRemoteDoctorSummary) -> DaemonRemoteDoctorCheck {
    if summary.active_client_count == 0 {
        DaemonRemoteDoctorCheck::warn("remote_clients", "no active remote clients")
    } else {
        DaemonRemoteDoctorCheck::pass(
            "remote_clients",
            format!("{} active remote clients", summary.active_client_count),
        )
    }
}

fn record_remote_doctor_audit(
    db: &DaemonDb,
    event_id: &str,
    recorded_at: &str,
    outcome: RemoteAuditOutcome,
) -> Result<(), CliError> {
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        event_id,
        recorded_at,
        None,
        None,
        "remote.doctor",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        outcome,
        None,
        None,
    ))
}

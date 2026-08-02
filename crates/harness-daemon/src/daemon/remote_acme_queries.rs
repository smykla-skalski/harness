//! `db`'s interface onto [`DaemonDb`] for remote ACME certificate state.
//!
//! `db/remote_acme.rs` keeps this area's SQL and row parsing, but the trait
//! and its impl live here, next to the domain code that calls them
//! (`harness-daemon-remote-cli`, `daemon::remote_acme_renewal`) rather than
//! inside `db`. `db` doesn't own `DaemonDb`'s callers, and an inherent `impl
//! DaemonDb` block for this area could never move into a crate `db` doesn't
//! share with them; a trait this module declares has no such problem, since
//! Rust's orphan rule only needs one of the trait or the implementing type to
//! be local. `RemoteAcmeStoredState` and `RemoteAcmeRenewalStatus` moved here
//! too, for the same reason `RemoteStoredClient` already lives in
//! `daemon::remote_identity` rather than `db`: a type a trait's signature
//! returns has to live somewhere that stays reachable without reaching into
//! `db`.

use rusqlite::{OptionalExtension, params};

use harness_kernel::errors::CliError;

use crate::daemon::db::DaemonDb;
use crate::daemon::db::db_error;
use crate::daemon::db::remote_acme::{
    SELECT_REMOTE_ACME_ISSUANCE_STATE_SQL, SELECT_REMOTE_ACME_RUNTIME_STATE_SQL,
    SELECT_REMOTE_ACME_STATE_SQL, remote_acme_issuance_state_from_row,
    remote_acme_runtime_state_from_row, remote_acme_state_from_row,
};

use super::remote::{RemoteDaemonServeConfig, RemoteDnsProvider, validate_remote_serve_config};
use super::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeIssuanceState, RemoteAcmeRuntimeState,
    RemoteCertificateBundle, RemoteRenewalOutcome,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAcmeRenewalStatus {
    Unknown,
    Succeeded,
    Failed,
}

impl RemoteAcmeRenewalStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteAcmeStoredState {
    pub account_configured: bool,
    pub account_id: Option<String>,
    pub serve_config: Option<RemoteDaemonServeConfig>,
    pub certificate_configured: bool,
    pub certificate_fingerprint: Option<String>,
    pub renewal_status: RemoteAcmeRenewalStatus,
    pub renewal_error: Option<String>,
    pub updated_at: String,
}

/// `db`'s remote-ACME persistence, scoped to the account, certificate, and
/// renewal state the TLS runtime and doctor diagnostics read and write.
///
/// No `Send + Sync` bound: `DaemonDb` holds a `rusqlite::Connection`, which
/// is `!Sync`, unlike the async `*Queries` traits elsewhere in `db` that this
/// mirrors.
pub trait RemoteAcmeQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL or status parsing failures.
    fn load_remote_acme_state(&self) -> Result<RemoteAcmeStoredState, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the singleton row is missing, SQL loading
    /// fails, or persisted account credentials are incomplete or invalid.
    fn load_remote_acme_issuance_state(&self) -> Result<RemoteAcmeIssuanceState, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure or if the singleton row is missing.
    fn record_remote_acme_account(
        &self,
        account: &RemoteAcmeAccountCredentials,
        updated_at: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the config is invalid, the singleton state row
    /// is missing, or the write fails.
    fn record_remote_acme_serve_config(
        &self,
        config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the singleton state row is missing or SQL
    /// loading fails.
    fn load_remote_acme_runtime_state(&self) -> Result<RemoteAcmeRuntimeState, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn record_remote_acme_renewal_failure(
        &self,
        detail: &str,
        updated_at: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure or if the singleton state row is
    /// unexpectedly missing.
    fn record_remote_acme_renewal_success(
        &self,
        bundle: &RemoteCertificateBundle,
        updated_at: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the conditional update cannot execute.
    fn record_remote_acme_renewal_success_if_current(
        &self,
        bundle: &RemoteCertificateBundle,
        expected_fingerprint: &str,
        expected_account_id: &str,
        expected_config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<bool, CliError>;
}

impl RemoteAcmeQueries for DaemonDb {
    fn load_remote_acme_state(&self) -> Result<RemoteAcmeStoredState, CliError> {
        self.connection()
            .query_row(SELECT_REMOTE_ACME_STATE_SQL, [], remote_acme_state_from_row)
            .optional()
            .map_err(|error| db_error(format!("load remote acme state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    fn load_remote_acme_issuance_state(&self) -> Result<RemoteAcmeIssuanceState, CliError> {
        self.connection()
            .query_row(
                SELECT_REMOTE_ACME_ISSUANCE_STATE_SQL,
                [],
                remote_acme_issuance_state_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote acme issuance state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    fn record_remote_acme_account(
        &self,
        account: &RemoteAcmeAccountCredentials,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let changed = self
            .connection()
            .execute(
                "UPDATE remote_acme_state
                 SET account_id = ?1,
                     account_credentials_json = ?2,
                     updated_at = ?3
                 WHERE singleton = 1",
                params![account.account_id(), account.serialized(), updated_at],
            )
            .map_err(|error| db_error(format!("record remote acme account: {error}")))?;
        if changed == 0 {
            return Err(db_error("remote acme singleton state row is missing"));
        }
        Ok(())
    }

    fn record_remote_acme_serve_config(
        &self,
        config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<(), CliError> {
        validate_remote_serve_config(config)
            .map_err(|error| db_error(format!("validate remote acme serve config: {error}")))?;
        let changed = self
            .connection()
            .execute(
                "UPDATE remote_acme_state
                 SET domain = ?1,
                     host = ?2,
                     https_port = ?3,
                     http_port = ?4,
                     acme_email = ?5,
                     acme_challenge = ?6,
                     acme_dns_provider = ?7,
                     updated_at = ?8
                 WHERE singleton = 1",
                params![
                    config.domain.trim(),
                    config.host.trim(),
                    i64::from(config.https_port),
                    i64::from(config.http_port),
                    config.acme_email.trim(),
                    config.acme_challenge.as_str(),
                    config.acme_dns_provider.map(RemoteDnsProvider::as_str),
                    updated_at,
                ],
            )
            .map_err(|error| db_error(format!("record remote acme serve config: {error}")))?;
        if changed == 0 {
            return Err(db_error("remote acme singleton state row is missing"));
        }
        Ok(())
    }

    fn load_remote_acme_runtime_state(&self) -> Result<RemoteAcmeRuntimeState, CliError> {
        self.connection()
            .query_row(
                SELECT_REMOTE_ACME_RUNTIME_STATE_SQL,
                [],
                remote_acme_runtime_state_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote acme runtime state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    fn record_remote_acme_renewal_failure(
        &self,
        detail: &str,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let report = RemoteRenewalOutcome::failure(detail).report().to_string();
        self.connection()
            .execute(
                "INSERT INTO remote_acme_state (
                     singleton, renewal_status, renewal_error, updated_at
                 ) VALUES (1, 'failed', ?1, ?2)
                 ON CONFLICT(singleton) DO UPDATE SET
                     renewal_status = excluded.renewal_status,
                     renewal_error = excluded.renewal_error,
                     updated_at = excluded.updated_at",
                params![report, updated_at],
            )
            .map_err(|error| db_error(format!("record remote acme renewal failure: {error}")))?;
        Ok(())
    }

    fn record_remote_acme_renewal_success(
        &self,
        bundle: &RemoteCertificateBundle,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let changed = self
            .connection()
            .execute(
                "UPDATE remote_acme_state
                 SET certificate_pem = ?1,
                     private_key_pem = ?2,
                     certificate_fingerprint = ?3,
                     renewal_status = 'succeeded',
                     renewal_error = NULL,
                     updated_at = ?4
                 WHERE singleton = 1",
                params![
                    bundle.certificate_pem(),
                    bundle.private_key_pem(),
                    bundle.fingerprint(),
                    updated_at,
                ],
            )
            .map_err(|error| db_error(format!("record remote acme renewal success: {error}")))?;
        if changed == 0 {
            return Err(db_error("remote acme singleton state row is missing"));
        }
        Ok(())
    }

    fn record_remote_acme_renewal_success_if_current(
        &self,
        bundle: &RemoteCertificateBundle,
        expected_fingerprint: &str,
        expected_account_id: &str,
        expected_config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<bool, CliError> {
        let changed = self
            .connection()
            .execute(
                "UPDATE remote_acme_state
                 SET certificate_pem = ?1,
                     private_key_pem = ?2,
                     certificate_fingerprint = ?3,
                     renewal_status = 'succeeded',
                     renewal_error = NULL,
                     updated_at = ?4
                 WHERE singleton = 1
                   AND certificate_fingerprint = ?5
                   AND account_id = ?6
                   AND domain = ?7
                   AND host = ?8
                   AND https_port = ?9
                   AND http_port = ?10
                   AND acme_email = ?11
                   AND acme_challenge = ?12
                   AND acme_dns_provider IS ?13",
                params![
                    bundle.certificate_pem(),
                    bundle.private_key_pem(),
                    bundle.fingerprint(),
                    updated_at,
                    expected_fingerprint,
                    expected_account_id,
                    expected_config.domain.trim(),
                    expected_config.host.trim(),
                    i64::from(expected_config.https_port),
                    i64::from(expected_config.http_port),
                    expected_config.acme_email.trim(),
                    expected_config.acme_challenge.as_str(),
                    expected_config
                        .acme_dns_provider
                        .map(RemoteDnsProvider::as_str),
                ],
            )
            .map_err(|error| {
                db_error(format!(
                    "record current remote acme renewal success: {error}"
                ))
            })?;
        Ok(changed == 1)
    }
}

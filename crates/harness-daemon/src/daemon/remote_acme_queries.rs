//! `db`'s interface onto [`DaemonDb`] for remote ACME certificate state.
//!
//! `db/remote_acme.rs` and `db/remote_acme_cas.rs` persist this area's
//! account, certificate, and renewal state, but the trait lives here, next to
//! the domain code that calls it (`harness-daemon-remote-cli`,
//! `daemon::remote_acme_renewal`) rather than inside `db`. `db` doesn't own
//! `DaemonDb`'s callers, and an inherent `impl DaemonDb` block for this area
//! could never move into a crate `db` doesn't share with them; a trait this
//! module declares has no such problem, since Rust's orphan rule only needs
//! one of the trait or the implementing type to be local. `RemoteAcmeStoredState`
//! and `RemoteAcmeRenewalStatus` moved here too, for the same reason
//! `RemoteStoredClient` already lives in `daemon::remote_identity` rather than
//! `db`: a type a trait's signature returns has to live somewhere that stays
//! reachable without reaching into `db`.

use harness_kernel::errors::CliError;

use crate::daemon::db::DaemonDb;

use super::remote::RemoteDaemonServeConfig;
use super::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeIssuanceState, RemoteAcmeRuntimeState,
    RemoteCertificateBundle,
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
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
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

/// The trait's one and only impl for [`DaemonDb`]. Every method is a thin
/// forward into the matching inherent method (`db/remote_acme.rs`,
/// `db/remote_acme_cas.rs`), kept on `Self` so nothing outside `db` has to
/// change to keep calling them by the same name.
impl RemoteAcmeQueries for DaemonDb {
    fn load_remote_acme_state(&self) -> Result<RemoteAcmeStoredState, CliError> {
        Self::load_remote_acme_state(self)
    }

    fn load_remote_acme_issuance_state(&self) -> Result<RemoteAcmeIssuanceState, CliError> {
        Self::load_remote_acme_issuance_state(self)
    }

    fn record_remote_acme_account(
        &self,
        account: &RemoteAcmeAccountCredentials,
        updated_at: &str,
    ) -> Result<(), CliError> {
        Self::record_remote_acme_account(self, account, updated_at)
    }

    fn record_remote_acme_serve_config(
        &self,
        config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<(), CliError> {
        Self::record_remote_acme_serve_config(self, config, updated_at)
    }

    fn load_remote_acme_runtime_state(&self) -> Result<RemoteAcmeRuntimeState, CliError> {
        Self::load_remote_acme_runtime_state(self)
    }

    fn record_remote_acme_renewal_failure(
        &self,
        detail: &str,
        updated_at: &str,
    ) -> Result<(), CliError> {
        Self::record_remote_acme_renewal_failure(self, detail, updated_at)
    }

    fn record_remote_acme_renewal_success(
        &self,
        bundle: &RemoteCertificateBundle,
        updated_at: &str,
    ) -> Result<(), CliError> {
        Self::record_remote_acme_renewal_success(self, bundle, updated_at)
    }

    fn record_remote_acme_renewal_success_if_current(
        &self,
        bundle: &RemoteCertificateBundle,
        expected_fingerprint: &str,
        expected_account_id: &str,
        expected_config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<bool, CliError> {
        Self::record_remote_acme_renewal_success_if_current(
            self,
            bundle,
            expected_fingerprint,
            expected_account_id,
            expected_config,
            updated_at,
        )
    }
}

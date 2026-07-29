use rusqlite::params;

use super::{CliError, DaemonDb, db_error};
use crate::daemon::remote::{RemoteDaemonServeConfig, RemoteDnsProvider};
use crate::daemon::remote_acme::RemoteCertificateBundle;

impl DaemonDb {
    /// Persist an automatically renewed certificate only when the ACME state
    /// still matches the snapshot used to place the order.
    ///
    /// # Errors
    /// Returns [`CliError`] when the conditional update cannot execute.
    pub(crate) fn record_remote_acme_renewal_success_if_current(
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

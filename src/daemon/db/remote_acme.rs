use rusqlite::{OptionalExtension, params, types::Type};

use super::{CliError, DaemonDb, db_error};
use crate::daemon::remote::{
    RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, validate_remote_serve_config,
};
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeIssuanceState, RemoteAcmeRuntimeState,
    RemoteCertificateBundle, RemoteRenewalOutcome,
};

const SELECT_REMOTE_ACME_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    CASE
        WHEN COALESCE(TRIM(account_id), '') <> ''
         AND COALESCE(TRIM(account_credentials_json), '') <> ''
        THEN 1 ELSE 0
    END,
    CASE
        WHEN COALESCE(TRIM(certificate_pem), '') <> ''
         AND COALESCE(TRIM(private_key_pem), '') <> ''
         AND COALESCE(TRIM(certificate_fingerprint), '') <> ''
        THEN 1 ELSE 0
    END,
    NULLIF(TRIM(certificate_fingerprint), ''),
    renewal_status,
    renewal_error,
    updated_at,
    NULLIF(TRIM(domain), ''),
    NULLIF(TRIM(host), ''),
    https_port,
    http_port,
    NULLIF(TRIM(acme_email), ''),
    NULLIF(TRIM(acme_challenge), ''),
    NULLIF(TRIM(acme_dns_provider), '')
FROM remote_acme_state
WHERE singleton = 1";

const SELECT_REMOTE_ACME_ISSUANCE_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    NULLIF(TRIM(account_credentials_json), ''),
    CASE WHEN COALESCE(TRIM(private_key_pem), '') <> '' THEN private_key_pem END
FROM remote_acme_state
WHERE singleton = 1";

const SELECT_REMOTE_ACME_RUNTIME_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    NULLIF(TRIM(account_credentials_json), ''),
    certificate_pem,
    private_key_pem
FROM remote_acme_state
WHERE singleton = 1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteAcmeRenewalStatus {
    Unknown,
    Succeeded,
    Failed,
}

impl RemoteAcmeRenewalStatus {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteAcmeStoredState {
    pub(crate) account_configured: bool,
    pub(crate) account_id: Option<String>,
    pub(crate) serve_config: Option<RemoteDaemonServeConfig>,
    pub(crate) certificate_configured: bool,
    pub(crate) certificate_fingerprint: Option<String>,
    pub(crate) renewal_status: RemoteAcmeRenewalStatus,
    pub(crate) renewal_error: Option<String>,
    pub(crate) updated_at: String,
}

impl DaemonDb {
    /// Load token-safe remote ACME status from the singleton state row.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or status parsing failures.
    pub(crate) fn load_remote_acme_state(&self) -> Result<RemoteAcmeStoredState, CliError> {
        self.conn
            .query_row(SELECT_REMOTE_ACME_STATE_SQL, [], remote_acme_state_from_row)
            .optional()
            .map_err(|error| db_error(format!("load remote acme state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    /// Load secret ACME account material for certificate issuance.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton row is missing, SQL loading
    /// fails, or persisted account credentials are incomplete or invalid.
    pub(crate) fn load_remote_acme_issuance_state(
        &self,
    ) -> Result<RemoteAcmeIssuanceState, CliError> {
        self.conn
            .query_row(
                SELECT_REMOTE_ACME_ISSUANCE_STATE_SQL,
                [],
                remote_acme_issuance_state_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote acme issuance state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    /// Persist an ACME account id and its opaque serialized credentials.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure or if the singleton row is missing.
    pub(crate) fn record_remote_acme_account(
        &self,
        account: &RemoteAcmeAccountCredentials,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let changed = self
            .conn
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

    /// Persist the remote serve config needed for later ACME issuance.
    ///
    /// # Errors
    /// Returns [`CliError`] when the config is invalid, the singleton state row
    /// is missing, or the write fails.
    pub(crate) fn record_remote_acme_serve_config(
        &self,
        config: &RemoteDaemonServeConfig,
        updated_at: &str,
    ) -> Result<(), CliError> {
        validate_remote_serve_config(config)
            .map_err(|error| db_error(format!("validate remote acme serve config: {error}")))?;
        let changed = self
            .conn
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

    /// Load remote ACME account and certificate material for the TLS runtime.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton state row is missing or SQL
    /// loading fails.
    pub(crate) fn load_remote_acme_runtime_state(
        &self,
    ) -> Result<RemoteAcmeRuntimeState, CliError> {
        self.conn
            .query_row(
                SELECT_REMOTE_ACME_RUNTIME_STATE_SQL,
                [],
                remote_acme_runtime_state_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote acme runtime state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    /// Persist a redacted ACME renewal failure report.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) fn record_remote_acme_renewal_failure(
        &self,
        detail: &str,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let report = RemoteRenewalOutcome::failure(detail).report().to_string();
        self.conn
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

    /// Persist a successful ACME renewal certificate bundle.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure or if the singleton state row is
    /// unexpectedly missing.
    pub(crate) fn record_remote_acme_renewal_success(
        &self,
        bundle: &RemoteCertificateBundle,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let changed = self
            .conn
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
}

fn remote_acme_state_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RemoteAcmeStoredState> {
    let status_label = row.get::<_, String>(4)?;
    Ok(RemoteAcmeStoredState {
        account_id: row.get(0)?,
        account_configured: row.get::<_, i64>(1)? != 0,
        serve_config: remote_acme_serve_config_from_row(row)?,
        certificate_configured: row.get::<_, i64>(2)? != 0,
        certificate_fingerprint: row.get(3)?,
        renewal_status: parse_renewal_status_at_column(&status_label, 4)?,
        renewal_error: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

fn remote_acme_issuance_state_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RemoteAcmeIssuanceState> {
    let account_id = row.get::<_, Option<String>>(0)?;
    let serialized = row.get::<_, Option<String>>(1)?;
    let account = remote_acme_account_from_columns(account_id, serialized)?;
    Ok(RemoteAcmeIssuanceState {
        account,
        previous_private_key_pem: row.get(2)?,
    })
}

fn remote_acme_account_from_columns(
    account_id: Option<String>,
    serialized: Option<String>,
) -> rusqlite::Result<Option<RemoteAcmeAccountCredentials>> {
    Ok(match (account_id, serialized) {
        (None | Some(_), None) => None,
        (Some(account_id), Some(serialized)) => Some(
            RemoteAcmeAccountCredentials::new(&account_id, &serialized).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(1, Type::Text, error.into())
            })?,
        ),
        (None, Some(serialized)) => {
            let value =
                serde_json::from_str::<serde_json::Value>(&serialized).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(1, Type::Text, error.into())
                })?;
            let account_id = value
                .get("id")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        Type::Text,
                        "remote acme serialized credentials omit account id".into(),
                    )
                })?;
            Some(
                RemoteAcmeAccountCredentials::new(account_id, &serialized).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(1, Type::Text, error.into())
                })?,
            )
        }
    })
}

fn remote_acme_serve_config_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<Option<RemoteDaemonServeConfig>> {
    let domain = row.get::<_, Option<String>>(7)?;
    let host = row.get::<_, Option<String>>(8)?;
    let tls_listener_port = row.get::<_, Option<i64>>(9)?;
    let challenge_listener_port = row.get::<_, Option<i64>>(10)?;
    let acme_email = row.get::<_, Option<String>>(11)?;
    let acme_challenge = row.get::<_, Option<String>>(12)?;
    let acme_dns_provider = row.get::<_, Option<String>>(13)?;
    if domain.is_none()
        && host.is_none()
        && tls_listener_port.is_none()
        && challenge_listener_port.is_none()
        && acme_email.is_none()
        && acme_challenge.is_none()
        && acme_dns_provider.is_none()
    {
        return Ok(None);
    }
    let config = RemoteDaemonServeConfig {
        domain: required_acme_config_text(domain, 7, "domain")?,
        host: required_acme_config_text(host, 8, "host")?,
        https_port: required_acme_config_port(tls_listener_port, 9, "https_port")?,
        http_port: required_acme_config_port(challenge_listener_port, 10, "http_port")?,
        acme_email: required_acme_config_text(acme_email, 11, "acme_email")?,
        acme_challenge: parse_acme_challenge_at_column(
            &required_acme_config_text(acme_challenge, 12, "acme_challenge")?,
            12,
        )?,
        acme_dns_provider: acme_dns_provider
            .as_deref()
            .map(|label| parse_dns_provider_at_column(label, 13))
            .transpose()?,
    };
    validate_remote_serve_config(&config).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            7,
            Type::Text,
            format!("invalid remote acme serve config: {error}").into(),
        )
    })?;
    Ok(Some(config))
}

fn required_acme_config_text(
    value: Option<String>,
    column: usize,
    label: &str,
) -> rusqlite::Result<String> {
    value
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(
                column,
                Type::Text,
                format!("remote acme serve config {label} is required").into(),
            )
        })
}

fn required_acme_config_port(
    value: Option<i64>,
    column: usize,
    label: &str,
) -> rusqlite::Result<u16> {
    let value = value.ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Integer,
            format!("remote acme serve config {label} is required").into(),
        )
    })?;
    u16::try_from(value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Integer,
            format!("invalid remote acme serve config {label}: {error}").into(),
        )
    })
}

fn parse_acme_challenge_at_column(
    label: &str,
    column: usize,
) -> rusqlite::Result<RemoteAcmeChallenge> {
    match label {
        "tls-alpn" => Ok(RemoteAcmeChallenge::TlsAlpn),
        "http" => Ok(RemoteAcmeChallenge::Http),
        "dns" => Ok(RemoteAcmeChallenge::Dns),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote acme challenge '{label}'").into(),
        )),
    }
}

fn parse_dns_provider_at_column(label: &str, column: usize) -> rusqlite::Result<RemoteDnsProvider> {
    match label {
        "aftermarket" => Ok(RemoteDnsProvider::Aftermarket),
        "cloudflare" => Ok(RemoteDnsProvider::Cloudflare),
        "route53" => Ok(RemoteDnsProvider::Route53),
        "exec" => Ok(RemoteDnsProvider::Exec),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote DNS provider '{label}'").into(),
        )),
    }
}

fn remote_acme_runtime_state_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RemoteAcmeRuntimeState> {
    let account = remote_acme_account_from_columns(
        row.get::<_, Option<String>>(0)?,
        row.get::<_, Option<String>>(1)?,
    )?;
    let Some(account) = account else {
        return Ok(RemoteAcmeRuntimeState::default());
    };
    let certificate_pem = row.get::<_, Option<String>>(2)?;
    let private_key_pem = row.get::<_, Option<String>>(3)?;
    if let (Some(certificate_pem), Some(private_key_pem)) = (certificate_pem, private_key_pem)
        && !certificate_pem.trim().is_empty()
        && !private_key_pem.trim().is_empty()
    {
        return Ok(RemoteAcmeRuntimeState::with_account_and_certificate(
            account.account_id(),
            RemoteCertificateBundle::new(&certificate_pem, &private_key_pem),
        ));
    }
    Ok(RemoteAcmeRuntimeState::with_account(account.account_id()))
}

fn parse_renewal_status_at_column(
    label: &str,
    column: usize,
) -> rusqlite::Result<RemoteAcmeRenewalStatus> {
    match label {
        "unknown" => Ok(RemoteAcmeRenewalStatus::Unknown),
        "succeeded" => Ok(RemoteAcmeRenewalStatus::Succeeded),
        "failed" => Ok(RemoteAcmeRenewalStatus::Failed),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote acme renewal status '{label}'").into(),
        )),
    }
}

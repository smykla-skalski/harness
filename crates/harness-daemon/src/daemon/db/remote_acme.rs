use rusqlite::types::Type;

use crate::daemon::remote::{
    RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, validate_remote_serve_config,
};
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeIssuanceState, RemoteAcmeRuntimeState,
    RemoteCertificateBundle,
};
use crate::daemon::remote_acme_queries::{RemoteAcmeRenewalStatus, RemoteAcmeStoredState};

pub(crate) const SELECT_REMOTE_ACME_STATE_SQL: &str = "
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

pub(crate) const SELECT_REMOTE_ACME_ISSUANCE_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    NULLIF(TRIM(account_credentials_json), ''),
    CASE WHEN COALESCE(TRIM(private_key_pem), '') <> '' THEN private_key_pem END
FROM remote_acme_state
WHERE singleton = 1";

pub(crate) const SELECT_REMOTE_ACME_RUNTIME_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    NULLIF(TRIM(account_credentials_json), ''),
    certificate_pem,
    private_key_pem
FROM remote_acme_state
WHERE singleton = 1";

pub(crate) fn remote_acme_state_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RemoteAcmeStoredState> {
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

pub(crate) fn remote_acme_issuance_state_from_row(
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

pub(crate) fn remote_acme_runtime_state_from_row(
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

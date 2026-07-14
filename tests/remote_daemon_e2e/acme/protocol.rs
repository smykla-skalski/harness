use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::header::{CONTENT_TYPE, LOCATION};
use axum::http::{HeaderValue, Method, StatusCode, Uri};
use axum::response::Response;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{Datelike as _, Duration as ChronoDuration, Utc};
use rcgen::{CertificateSigningRequestParams, ExtendedKeyUsagePurpose, date_time_ymd};
use rustls::pki_types::CertificateSigningRequestDer;
use serde_json::{Value, json};

use super::{AcmeChallenge, DNS_TOKEN, FakeAcmeState, HTTP_TOKEN, TLS_TOKEN, validation};

pub(super) async fn handle_acme_request(
    State(state): State<Arc<FakeAcmeState>>,
    method: Method,
    uri: Uri,
    body: Bytes,
) -> Response<Body> {
    match route_acme_request(&state, &method, uri.path(), &body).await {
        Ok(response) => response,
        Err(error) => {
            if let Ok(mut progress) = state.progress.lock() {
                progress.validation_error = Some(error.clone());
            }
            response(StatusCode::INTERNAL_SERVER_ERROR, "text/plain", error)
        }
    }
}

async fn route_acme_request(
    state: &FakeAcmeState,
    method: &Method,
    path: &str,
    body: &[u8],
) -> Result<Response<Body>, String> {
    if *method == Method::GET && path == "/directory" {
        return Ok(json_response(
            StatusCode::OK,
            &directory_body(&state.origin),
            None,
        ));
    }
    if *method == Method::HEAD && path == "/new-nonce" {
        return Ok(acme_response(StatusCode::OK, "application/json", "", None));
    }
    if *method != Method::POST {
        return Ok(response(
            StatusCode::METHOD_NOT_ALLOWED,
            "text/plain",
            format!("unsupported fake ACME method {method} for {path}"),
        ));
    }
    match path {
        "/new-account" => Ok(json_response(
            StatusCode::CREATED,
            &json!({}),
            Some(format!("{}/acct/1", state.origin)),
        )),
        "/new-order" => begin_order(state),
        "/authz/1" => Ok(json_response(
            StatusCode::OK,
            &authorization_body(state),
            None,
        )),
        "/order/1" => order_status(state),
        "/order/1/finalize" => finalize_order(state, body),
        "/cert/1" => download_certificate(state),
        path if path == state.config.challenge.challenge_path() => {
            validation::verify_challenge(&state.config).await?;
            state
                .progress
                .lock()
                .map_err(|_| "fake ACME progress lock poisoned".to_string())?
                .challenge_validated = true;
            Ok(json_response(StatusCode::OK, &challenge_body(state), None))
        }
        _ => Ok(response(
            StatusCode::NOT_FOUND,
            "text/plain",
            format!("unknown fake ACME path {path}"),
        )),
    }
}

fn begin_order(state: &FakeAcmeState) -> Result<Response<Body>, String> {
    let mut progress = state
        .progress
        .lock()
        .map_err(|_| "fake ACME progress lock poisoned".to_string())?;
    reset_for_new_order(&mut progress);
    drop(progress);
    Ok(json_response(
        StatusCode::CREATED,
        &order_body(state, "pending", false),
        Some(format!("{}/order/1", state.origin)),
    ))
}

fn reset_for_new_order(progress: &mut super::FakeAcmeProgress) {
    progress.order_count += 1;
    progress.challenge_validated = false;
    progress.finalized = false;
    progress.certificate_pem = None;
    progress.certificate_downloaded = false;
}

fn order_status(state: &FakeAcmeState) -> Result<Response<Body>, String> {
    let finalized = state
        .progress
        .lock()
        .map_err(|_| "fake ACME progress lock poisoned".to_string())?
        .finalized;
    Ok(json_response(
        StatusCode::OK,
        &order_body(state, if finalized { "valid" } else { "ready" }, finalized),
        None,
    ))
}

fn finalize_order(state: &FakeAcmeState, body: &[u8]) -> Result<Response<Body>, String> {
    let payload = jws_payload(body)?;
    let csr = payload["csr"]
        .as_str()
        .ok_or_else(|| "fake ACME finalize request omitted CSR".to_string())?;
    let csr = URL_SAFE_NO_PAD
        .decode(csr)
        .map_err(|error| format!("decode fake ACME CSR: {error}"))?;
    let csr = CertificateSigningRequestDer::from(csr);
    let mut request = CertificateSigningRequestParams::from_der(&csr)
        .map_err(|error| format!("parse fake ACME CSR: {error}"))?;
    let now = Utc::now().date_naive();
    let not_before = now
        .checked_sub_signed(ChronoDuration::days(1))
        .ok_or_else(|| "build fake ACME certificate start date".to_string())?;
    let validity_days = i64::try_from(state.config.certificate_validity_days)
        .map_err(|_| "fake ACME certificate validity is too large".to_string())?;
    let not_after = now
        .checked_add_signed(ChronoDuration::days(validity_days))
        .ok_or_else(|| "build fake ACME certificate expiry date".to_string())?;
    request.params.not_before = date_time_ymd(
        not_before.year(),
        not_before.month() as u8,
        not_before.day() as u8,
    );
    request.params.not_after = date_time_ymd(
        not_after.year(),
        not_after.month() as u8,
        not_after.day() as u8,
    );
    request.params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let certificate = request
        .signed_by(&state.issuer)
        .map_err(|error| format!("sign fake ACME CSR: {error}"))?;
    let chain = format!("{}\n{}", certificate.pem(), state.issuer.pem());
    let mut progress = state
        .progress
        .lock()
        .map_err(|_| "fake ACME progress lock poisoned".to_string())?;
    progress.finalized = true;
    progress.certificate_pem = Some(chain);
    Ok(json_response(
        StatusCode::OK,
        &order_body(state, "processing", false),
        None,
    ))
}

fn download_certificate(state: &FakeAcmeState) -> Result<Response<Body>, String> {
    let mut progress = state
        .progress
        .lock()
        .map_err(|_| "fake ACME progress lock poisoned".to_string())?;
    let certificate = progress
        .certificate_pem
        .clone()
        .ok_or_else(|| "fake ACME certificate requested before finalize".to_string())?;
    record_certificate_download(&mut progress, &certificate);
    Ok(acme_response(
        StatusCode::OK,
        "application/pem-certificate-chain",
        certificate,
        None,
    ))
}

fn record_certificate_download(progress: &mut super::FakeAcmeProgress, certificate: &str) {
    let first_download_for_order = !progress.certificate_downloaded;
    progress.certificate_downloaded = true;
    progress.certificate_download_count += 1;
    if first_download_for_order {
        progress
            .issued_certificate_pems
            .push(certificate.to_string());
    }
}

fn directory_body(origin: &str) -> Value {
    json!({
        "newNonce": format!("{origin}/new-nonce"),
        "newAccount": format!("{origin}/new-account"),
        "newOrder": format!("{origin}/new-order"),
    })
}

fn authorization_body(state: &FakeAcmeState) -> Value {
    json!({
        "identifier": { "type": "dns", "value": state.config.domain },
        "status": "pending",
        "challenges": [
            challenge_descriptor(&state.origin, "http-01", "/challenge/http/1", HTTP_TOKEN),
            challenge_descriptor(&state.origin, "dns-01", "/challenge/dns/1", DNS_TOKEN),
            challenge_descriptor(&state.origin, "tls-alpn-01", "/challenge/tls/1", TLS_TOKEN),
        ],
    })
}

fn challenge_descriptor(origin: &str, kind: &str, path: &str, token: &str) -> Value {
    json!({
        "type": kind,
        "url": format!("{origin}{path}"),
        "token": token,
        "status": "pending",
        "error": null,
    })
}

fn challenge_body(state: &FakeAcmeState) -> Value {
    let (kind, token) = match state.config.challenge {
        AcmeChallenge::Http => ("http-01", HTTP_TOKEN),
        AcmeChallenge::Dns => ("dns-01", DNS_TOKEN),
        AcmeChallenge::TlsAlpn => ("tls-alpn-01", TLS_TOKEN),
    };
    challenge_descriptor(
        &state.origin,
        kind,
        state.config.challenge.challenge_path(),
        token,
    )
}

fn order_body(state: &FakeAcmeState, status: &str, with_certificate: bool) -> Value {
    json!({
        "status": status,
        "authorizations": [format!("{}/authz/1", state.origin)],
        "finalize": format!("{}/order/1/finalize", state.origin),
        "certificate": with_certificate.then(|| format!("{}/cert/1", state.origin)),
        "error": null,
    })
}

fn json_response(status: StatusCode, value: &Value, location: Option<String>) -> Response<Body> {
    acme_response(status, "application/json", value.to_string(), location)
}

fn acme_response(
    status: StatusCode,
    content_type: &'static str,
    body: impl Into<String>,
    location: Option<String>,
) -> Response<Body> {
    let mut response = response(status, content_type, body);
    response
        .headers_mut()
        .insert("replay-nonce", HeaderValue::from_static("remote-e2e-nonce"));
    if let Some(location) = location
        && let Ok(location) = HeaderValue::from_str(&location)
    {
        response.headers_mut().insert(LOCATION, location);
    }
    response
}

fn response(
    status: StatusCode,
    content_type: &'static str,
    body: impl Into<String>,
) -> Response<Body> {
    let mut response = Response::new(Body::from(body.into()));
    *response.status_mut() = status;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static(content_type));
    response
}

fn jws_payload(body: &[u8]) -> Result<Value, String> {
    let envelope = serde_json::from_slice::<Value>(body)
        .map_err(|error| format!("decode fake ACME JWS envelope: {error}"))?;
    let payload = envelope["payload"]
        .as_str()
        .ok_or_else(|| "fake ACME JWS omitted payload".to_string())?;
    let payload = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|error| format!("decode fake ACME JWS payload: {error}"))?;
    serde_json::from_slice(&payload)
        .map_err(|error| format!("decode fake ACME JWS payload JSON: {error}"))
}

#[cfg(test)]
mod tests {
    use super::{record_certificate_download, reset_for_new_order};
    use crate::acme::FakeAcmeProgress;

    #[test]
    fn new_order_preserves_prior_protocol_failure() {
        let mut progress = FakeAcmeProgress {
            validation_error: Some("challenge validation failed".to_string()),
            ..FakeAcmeProgress::default()
        };

        reset_for_new_order(&mut progress);

        assert_eq!(
            progress.validation_error.as_deref(),
            Some("challenge validation failed")
        );
    }

    #[test]
    fn certificate_download_retry_records_one_issued_chain_per_order() {
        let mut progress = FakeAcmeProgress::default();
        reset_for_new_order(&mut progress);

        record_certificate_download(&mut progress, "first-chain");
        record_certificate_download(&mut progress, "first-chain");

        assert_eq!(progress.certificate_download_count, 2);
        assert_eq!(progress.issued_certificate_pems, ["first-chain"]);

        reset_for_new_order(&mut progress);
        record_certificate_download(&mut progress, "second-chain");

        assert_eq!(progress.certificate_download_count, 3);
        assert_eq!(
            progress.issued_certificate_pems,
            ["first-chain", "second-chain"]
        );
    }
}

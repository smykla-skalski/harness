use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::header::{CONTENT_TYPE, LOCATION};
use axum::http::{HeaderValue, Method, StatusCode, Uri};
use axum::response::Response;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rcgen::CertificateSigningRequestParams;
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
        "/new-order" => Ok(json_response(
            StatusCode::CREATED,
            &order_body(state, "pending", false),
            Some(format!("{}/order/1", state.origin)),
        )),
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
    let request = CertificateSigningRequestParams::from_der(&csr)
        .map_err(|error| format!("parse fake ACME CSR: {error}"))?;
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
    progress.certificate_downloaded = true;
    Ok(acme_response(
        StatusCode::OK,
        "application/pem-certificate-chain",
        certificate,
        None,
    ))
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

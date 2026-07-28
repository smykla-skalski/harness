#[cfg(target_os = "macos")]
use std::env;
use std::time::Duration;

use harness_kernel::errors::{CliError, CliErrorKind};
use reqwest::blocking::Client;

use super::SecretKindArg;

#[cfg(target_os = "macos")]
const DEFAULT_GITHUB_API_URL: &str = "https://api.github.com";
#[cfg(target_os = "macos")]
const DEFAULT_OPENROUTER_API_URL: &str = "https://openrouter.ai/api/v1";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[cfg(target_os = "macos")]
pub(super) fn validate_provider_secret(kind: SecretKindArg, secret: &str) -> Result<(), CliError> {
    let base_url = match kind {
        SecretKindArg::Github => env::var("HARNESS_GITHUB_API_URL")
            .unwrap_or_else(|_| DEFAULT_GITHUB_API_URL.to_string()),
        SecretKindArg::OpenRouter => env::var("OPENROUTER_API_URL")
            .unwrap_or_else(|_| DEFAULT_OPENROUTER_API_URL.to_string()),
        _ => unreachable!("provider credential kind required"),
    };
    validate_at(kind, secret, &base_url)
}

fn validate_at(kind: SecretKindArg, secret: &str, base_url: &str) -> Result<(), CliError> {
    let (provider, path) = match kind {
        SecretKindArg::Github => ("GitHub", "user"),
        SecretKindArg::OpenRouter => ("OpenRouter", "key"),
        _ => unreachable!("provider credential kind required"),
    };
    let url = format!("{}/{path}", base_url.trim_end_matches('/'));
    let client = Client::builder()
        .no_proxy()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| validation_error(provider, "could not build HTTP client"))?;
    let mut request = client
        .get(&url)
        .bearer_auth(secret)
        .header("User-Agent", "Harness");
    if matches!(kind, SecretKindArg::Github) {
        request = request
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28");
    } else {
        request = request
            .header("HTTP-Referer", "https://harness.dev")
            .header("X-Title", "Harness");
    }
    let response = request
        .send()
        .map_err(|_| validation_error(provider, "request failed"))?;
    if response.status().is_success() {
        return Ok(());
    }
    Err(validation_error(
        provider,
        &format!("credential rejected with HTTP {}", response.status()),
    ))
}

fn validation_error(provider: &str, detail: &str) -> CliError {
    CliErrorKind::workflow_io(format!("{provider} credential validation failed: {detail}")).into()
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};

    use super::*;

    fn serve_once(
        status: &str,
        expected_path: &str,
        expected_secret: &str,
    ) -> (String, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let address = listener.local_addr().expect("test server address");
        let expected_path = expected_path.to_string();
        let expected_secret = expected_secret.to_string();
        let status = status.to_string();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let mut request = [0_u8; 4096];
            let count = stream.read(&mut request).expect("read request");
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with(&format!("GET {expected_path} HTTP/1.1")));
            assert!(
                request
                    .to_lowercase()
                    .contains(&format!("authorization: bearer {expected_secret}"))
            );
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .expect("write response");
        });
        (format!("http://{address}"), server)
    }

    #[test]
    fn github_validation_authenticates_the_selected_secret() {
        let (base_url, server) = serve_once("200 OK", "/user", "github-secret");
        validate_at(SecretKindArg::Github, "github-secret", &base_url)
            .expect("GitHub credential should validate");
        server.join().expect("mock server should finish");
    }

    #[test]
    fn openrouter_rejection_names_provider_without_exposing_secret() {
        let (base_url, server) = serve_once("401 Unauthorized", "/key", "openrouter-secret");
        let error = validate_at(SecretKindArg::OpenRouter, "openrouter-secret", &base_url)
            .expect_err("OpenRouter credential should be rejected")
            .to_string();
        server.join().expect("mock server should finish");
        assert!(error.contains("OpenRouter credential validation failed"));
        assert!(error.contains("HTTP 401"));
        assert!(!error.contains("openrouter-secret"));
    }

    #[test]
    fn transport_failure_does_not_expose_secret_or_url() {
        let error = validate_at(SecretKindArg::Github, "github-secret", "not a url")
            .expect_err("invalid URL should fail")
            .to_string();
        assert!(error.contains("GitHub credential validation failed: request failed"));
        assert!(!error.contains("github-secret"));
        assert!(!error.contains("not a url"));
    }
}

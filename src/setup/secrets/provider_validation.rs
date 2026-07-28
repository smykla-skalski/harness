#[cfg(target_os = "macos")]
use std::env;
use std::time::Duration;

use harness_kernel::errors::{CliError, CliErrorKind};
use reqwest::{Url, blocking::Client};

use super::SecretKindArg;

#[cfg(target_os = "macos")]
const DEFAULT_GITHUB_API_URL: &str = "https://api.github.com";
#[cfg(target_os = "macos")]
const DEFAULT_OPENROUTER_API_URL: &str = "https://openrouter.ai/api/v1";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[cfg(target_os = "macos")]
pub(super) fn validate_provider_secret(kind: SecretKindArg, secret: &str) -> Result<(), CliError> {
    let base_url = match kind {
        SecretKindArg::Github => DEFAULT_GITHUB_API_URL.to_string(),
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
    let url = Url::parse(&format!("{}/{path}", base_url.trim_end_matches('/')))
        .map_err(|_| validation_error(provider, "invalid API URL"))?;
    let client = Client::builder()
        .no_proxy()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| validation_error(provider, "could not build HTTP client"))?;
    let mut request = client
        .get(url)
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
    let response = request.send().map_err(|error| {
        let detail = if error.is_timeout() {
            "request timed out"
        } else if error.is_connect() {
            "could not connect"
        } else {
            "request failed"
        };
        validation_error(provider, detail)
    })?;
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
            let authorization = request
                .lines()
                .filter_map(|line| line.split_once(':'))
                .find(|(name, _)| name.eq_ignore_ascii_case("authorization"))
                .map(|(_, value)| value.trim());
            let expected_authorization = format!("Bearer {expected_secret}");
            assert_eq!(authorization, Some(expected_authorization.as_str()));
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
        let (base_url, server) = serve_once("200 OK", "/user", "GitHub-Secret");
        validate_at(SecretKindArg::Github, "GitHub-Secret", &base_url)
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
    fn invalid_api_url_does_not_expose_secret_or_url() {
        let error = validate_at(SecretKindArg::Github, "github-secret", "not a url")
            .expect_err("invalid URL should fail")
            .to_string();
        assert!(error.contains("GitHub credential validation failed: invalid API URL"));
        assert!(!error.contains("github-secret"));
        assert!(!error.contains("not a url"));
    }

    #[test]
    fn connection_failure_does_not_expose_secret_or_url() {
        let base_url = "http://127.0.0.1:0";
        let error = validate_at(SecretKindArg::Github, "github-secret", base_url)
            .expect_err("connection should fail")
            .to_string();
        assert!(error.contains("GitHub credential validation failed: could not connect"));
        assert!(!error.contains("github-secret"));
        assert!(!error.contains(base_url));
    }
}

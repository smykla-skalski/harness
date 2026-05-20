use crate::errors::{CliError, CliErrorKind};

pub(crate) fn client_error(context: &str, error: octocrab::Error) -> CliError {
    error_with_context(context, error)
}

pub(crate) fn operation_error(context: &str, error: octocrab::Error) -> CliError {
    error_with_context(context, error)
}

fn error_with_context(context: &str, error: octocrab::Error) -> CliError {
    let summary = octocrab_error_summary(&error);
    let details = octocrab_error_details(&error);
    let mut cli_error = CliError::new(CliErrorKind::workflow_io(format!("{context}: {summary}")))
        .with_source(error);
    if let Some(details) = details {
        cli_error = cli_error.with_details(details);
    }
    cli_error
}

pub(crate) fn octocrab_error_summary(error: &octocrab::Error) -> String {
    match error {
        octocrab::Error::GitHub { source, .. } => github_api_error_summary(source),
        _ => error.to_string(),
    }
}

fn github_api_error_summary(error: &octocrab::GitHubError) -> String {
    let status_code = error.status_code.to_string();
    github_api_error_summary_parts(
        &status_code,
        error.status_code.as_u16(),
        error.message.as_str(),
        error.errors.as_deref(),
    )
}

fn github_api_error_summary_parts(
    status_code: &str,
    status_code_u16: u16,
    message: &str,
    errors: Option<&[serde_json::Value]>,
) -> String {
    let message = trimmed_terminal_period(message);
    let mut summary = format!("GitHub API returned {status_code}: {message}");
    if let Some(detail) = first_github_api_error_message(errors)
        && trimmed_terminal_period(&detail) != message
    {
        let detail = trimmed_terminal_period(&detail);
        summary.push_str(": ");
        summary.push_str(&detail);
    }
    if let Some(guidance) = github_api_error_guidance(status_code_u16, &message, errors) {
        summary.push_str(". ");
        summary.push_str(guidance);
    }
    summary
}

pub(crate) fn octocrab_error_details(error: &octocrab::Error) -> Option<String> {
    match error {
        octocrab::Error::GitHub { source, .. } => Some(github_api_error_details(source)),
        _ => None,
    }
}

fn github_api_error_details(error: &octocrab::GitHubError) -> String {
    let status_code = error.status_code.to_string();
    github_api_error_details_parts(
        &status_code,
        error.message.as_str(),
        error.errors.as_deref(),
        error.documentation_url.as_deref(),
    )
}

fn github_api_error_details_parts(
    status_code: &str,
    message: &str,
    errors: Option<&[serde_json::Value]>,
    documentation_url: Option<&str>,
) -> String {
    let mut details = format!("GitHub API status: {status_code}\nGitHub API message: {message}");
    if let Some(errors) = errors
        && !errors.is_empty()
    {
        details.push_str("\nGitHub API errors:");
        for error in errors {
            details.push_str("\n- ");
            details.push_str(&github_api_error_value_message(error));
        }
    }
    if let Some(documentation_url) = documentation_url {
        details.push_str("\nGitHub API documentation: ");
        details.push_str(documentation_url);
    }
    details
}

fn github_api_error_guidance(
    status_code: u16,
    message: &str,
    errors: Option<&[serde_json::Value]>,
) -> Option<&'static str> {
    match status_code {
        401 => Some("Check that the GitHub token is valid"),
        403 | 429 if github_api_error_mentions_rate_limit(message, errors) => Some(
            "GitHub rate limited this request; wait for the reset window or reduce GitHub refresh frequency",
        ),
        403 => Some("Check that the GitHub token has repository access and API rate limit"),
        404 => Some("Check that the repository exists and the GitHub token can read it"),
        422 if github_api_error_mentions_search_access(errors) => {
            Some("Check that the repository exists and the GitHub token can read it")
        }
        _ => None,
    }
}

fn github_api_error_mentions_rate_limit(
    message: &str,
    errors: Option<&[serde_json::Value]>,
) -> bool {
    github_error_text_mentions_rate_limit(message)
        || errors
            .into_iter()
            .flatten()
            .map(github_api_error_value_message)
            .any(|message| github_error_text_mentions_rate_limit(&message))
}

fn github_error_text_mentions_rate_limit(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("rate limit")
        || message.contains("secondary limit")
        || message.contains("abuse detection")
        || message.contains("too many requests")
}

fn github_api_error_mentions_search_access(errors: Option<&[serde_json::Value]>) -> bool {
    errors
        .into_iter()
        .flatten()
        .map(github_api_error_value_message)
        .any(|message| {
            message.contains("cannot be searched") || message.contains("do not have permission")
        })
}

fn first_github_api_error_message(errors: Option<&[serde_json::Value]>) -> Option<String> {
    errors
        .and_then(|errors| errors.first())
        .map(github_api_error_value_message)
}

fn github_api_error_value_message(error: &serde_json::Value) -> String {
    error
        .get("message")
        .and_then(serde_json::Value::as_str)
        .map_or_else(|| error.to_string(), ToOwned::to_owned)
}

fn trimmed_terminal_period(value: &str) -> String {
    value.trim_end().trim_end_matches('.').trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use axum::http::StatusCode;
    use serde_json::json;

    use super::*;

    #[test]
    fn github_api_error_summary_calls_out_primary_rate_limits() {
        let summary = github_api_error_summary_parts(
            StatusCode::FORBIDDEN.to_string().as_str(),
            StatusCode::FORBIDDEN.as_u16(),
            "API rate limit exceeded for user ID 1.",
            None,
        );

        assert!(summary.contains("GitHub rate limited this request"));
        assert!(!summary.contains("repository access"));
    }

    #[test]
    fn github_api_error_summary_explains_search_access_failures() {
        let errors = vec![json!({
                "message": "The listed users and repositories cannot be searched either because \
                    the resources do not exist or you do not have permission to view them.",
                "resource": "Search",
                "field": "q",
                "code": "invalid"
        })];

        let summary = github_api_error_summary_parts(
            StatusCode::UNPROCESSABLE_ENTITY.to_string().as_str(),
            StatusCode::UNPROCESSABLE_ENTITY.as_u16(),
            "Validation Failed",
            Some(&errors),
        );

        assert!(summary.contains("422 Unprocessable Entity"));
        assert!(summary.contains("cannot be searched"));
        assert!(summary.contains("GitHub token can read it"));
        assert!(!summary.contains(".. Check"));
    }

    #[test]
    fn github_api_error_details_preserve_structured_api_reason() {
        let errors = vec![json!({ "message": "Resource not accessible" })];

        let details = github_api_error_details_parts(
            StatusCode::FORBIDDEN.to_string().as_str(),
            "Forbidden",
            Some(&errors),
            Some("https://docs.github.com/rest"),
        );

        assert!(details.contains("403 Forbidden"));
        assert!(details.contains("Resource not accessible"));
        assert!(details.contains("https://docs.github.com/rest"));
    }

    #[test]
    fn github_api_error_summary_calls_out_secondary_rate_limits() {
        let errors = vec![json!({ "message": "You have exceeded a secondary rate limit" })];
        let summary = github_api_error_summary_parts(
            StatusCode::TOO_MANY_REQUESTS.to_string().as_str(),
            StatusCode::TOO_MANY_REQUESTS.as_u16(),
            "Too Many Requests",
            Some(&errors),
        );

        assert!(summary.contains("secondary rate limit"));
        assert!(summary.contains("GitHub rate limited this request"));
    }
}

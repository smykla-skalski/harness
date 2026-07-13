use std::borrow::Cow;
use std::sync::LazyLock;

use regex::Regex;

const REDACTED: &str = "[redacted]";

static KNOWN_SECRET_RULES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    vec![
        (
            Regex::new(
                r#"(?i)(\b(?:aws_secret_access_key|aws_access_key_id|github_token|gh_token|gitlab_token|openai_api_key|anthropic_api_key|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|private[_-]?key|token|secret|password|passwd|pwd)\b\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;]+)"#,
            )
            .expect("known secret key regex"),
            "$1[redacted]",
        ),
        (
            Regex::new(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}")
                .expect("bearer token regex"),
            "Bearer [redacted]",
        ),
        (
            Regex::new(r"(?i)(https?://)[^\s/@]+:[^\s/@]+@")
                .expect("URL credentials regex"),
            "$1[redacted]@",
        ),
        (
            Regex::new(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b").expect("GitHub PAT regex"),
            REDACTED,
        ),
        (
            Regex::new(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b").expect("GitHub token regex"),
            REDACTED,
        ),
        (
            Regex::new(r"\bglpat-[A-Za-z0-9_-]{20,}\b").expect("GitLab token regex"),
            REDACTED,
        ),
        (
            Regex::new(r"\bsk-[A-Za-z0-9]{20,}\b").expect("API token regex"),
            REDACTED,
        ),
        (
            Regex::new(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b").expect("Slack token regex"),
            REDACTED,
        ),
        (
            Regex::new(r"\bAKIA[0-9A-Z]{16}\b").expect("AWS access key regex"),
            REDACTED,
        ),
        (
            Regex::new(
                r"(?is)-----BEGIN [^-]*(?:PRIVATE KEY|SECRET|TOKEN).*?-----END [^-]*-----",
            )
            .expect("PEM secret regex"),
            REDACTED,
        ),
    ]
});

#[must_use]
pub(crate) fn redact_known_secrets(value: &str) -> String {
    apply_redaction_rules(value.to_string(), &KNOWN_SECRET_RULES)
}

fn apply_redaction_rules(mut redacted: String, rules: &[(Regex, &'static str)]) -> String {
    for (expression, replacement) in rules {
        let replaced = {
            match expression.replace_all(&redacted, *replacement) {
                Cow::Borrowed(_) => None,
                Cow::Owned(replaced) => Some(replaced),
            }
        };
        if let Some(replaced) = replaced {
            redacted = replaced;
        }
    }
    redacted
}

pub(crate) fn redact_secret_detail(detail: &str) -> String {
    let mut redacted = String::with_capacity(detail.len());
    let mut offset = 0;

    while offset < detail.len() {
        let rest = &detail[offset..];
        if let Some(key) = ["secret=", "token="]
            .into_iter()
            .find(|key| rest.starts_with(key))
        {
            redacted.push_str(key);
            redacted.push_str("<redacted>");
            offset += key.len();
            while let Some(value_char) = detail[offset..].chars().next() {
                if is_secret_value_terminator(value_char) {
                    break;
                }
                offset += value_char.len_utf8();
            }
        } else if let Some(plain_char) = rest.chars().next() {
            redacted.push(plain_char);
            offset += plain_char.len_utf8();
        }
    }

    redacted
}

fn is_secret_value_terminator(value_char: char) -> bool {
    value_char.is_whitespace()
        || matches!(value_char, '&' | ';' | ',' | ')' | ']' | '}' | '"' | '\'')
}

#[cfg(test)]
mod tests {
    use regex::Regex;

    use super::{apply_redaction_rules, redact_known_secrets};

    #[test]
    fn known_secret_redaction_matches_remote_client_policy() {
        let value = concat!(
            "api_key=alpha token=delta Bearer abcdefghijklmnop ",
            "https://user:password@example.com ",
            "github_pat_abcdefghijklmnopqrstuvwxyz123456 ",
            "AKIAABCDEFGHIJKLMNOP"
        );
        let redacted = redact_known_secrets(value);

        for secret in [
            "alpha",
            "delta",
            "abcdefghijklmnop",
            "user:password",
            "github_pat_",
            "AKIA",
        ] {
            assert!(!redacted.contains(secret), "secret remained: {secret}");
        }
        assert_eq!(redacted.matches("[redacted]").count(), 6);
    }

    #[test]
    fn no_match_rule_preserves_the_owned_buffer() {
        let mut value = String::with_capacity(64);
        value.push_str("ordinary viewer title");
        let original_buffer = value.as_ptr();
        let rules = [(Regex::new(r"secret=").expect("test regex"), "[redacted]")];

        let redacted = apply_redaction_rules(value, &rules);

        assert_eq!(redacted.as_ptr(), original_buffer);
        assert_eq!(redacted, "ordinary viewer title");
    }
}

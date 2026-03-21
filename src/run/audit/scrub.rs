use std::sync::LazyLock;

use regex::Regex;

/// Patterns and their replacement labels for secret scrubbing.
const SCRUB_PATTERNS: &[(&str, &str)] = &[
    // PEM blocks: certificates, private keys, public keys
    (
        r"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----",
        "[REDACTED:PEM]",
    ),
    // JWT tokens: three base64url segments separated by dots, min 20 chars each
    (
        r"eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}",
        "[REDACTED:JWT]",
    ),
    // Kubeconfig base64 data fields
    (
        r"(certificate-authority-data|client-certificate-data|client-key-data):\s*[A-Za-z0-9+/=]{40,}",
        "$1: [REDACTED:KUBECONFIG_DATA]",
    ),
    // Bearer token headers
    (
        r"(?i)(authorization:\s*bearer\s+)\S+",
        "$1[REDACTED:BEARER]",
    ),
    // Known secret environment variable assignments
    // Matches VAR_NAME=value where VAR_NAME ends with _TOKEN, _SECRET, _KEY, _PASSWORD
    (
        r"(?i)([A-Z_]*(?:TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL))\s*=\s*\S+",
        "$1=[REDACTED:ENV_SECRET]",
    ),
];

static COMPILED_PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    SCRUB_PATTERNS
        .iter()
        .map(|(pattern, replacement)| {
            (
                Regex::new(pattern).expect("invalid scrub regex"),
                *replacement,
            )
        })
        .collect()
});

/// Redact known secret patterns from text.
///
/// Applied before audit artifacts and JSONL summaries are persisted.
#[must_use]
pub fn scrub(text: &str) -> String {
    let mut result = text.to_string();
    for (pattern, replacement) in COMPILED_PATTERNS.iter() {
        result = pattern.replace_all(&result, *replacement).into_owned();
    }
    result
}

#[cfg(test)]
#[path = "scrub/tests.rs"]
mod tests;

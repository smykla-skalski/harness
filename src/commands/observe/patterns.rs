/// KSA hook codes to detect in Bash output (lowercase for matching against
/// lowercased text).
pub static KSA_CODES: &[&str] = &[
    "ksa001", "ksa002", "ksa003", "ksa004", "ksa005", "ksa006", "ksa007", "ksa008", "ksa009",
    "ksa010", "ksa011", "ksa012", "ksa013", "ksa014", "ksa015", "ksa016", "ksa017", "ksa018",
    "ksa019",
];

/// Patterns indicating harness CLI errors.
pub static CLI_ERROR_PATTERNS: &[&str] = &[
    "harness: error:",
    "unrecognized arguments",
    "invalid choice:",
    "the following arguments are required:",
    "harness: unable to resolve",
];

/// Patterns indicating Claude Code tool usage errors.
pub static TOOL_ERROR_PATTERNS: &[&str] = &[
    "file has not been read yet",
    "file has been modified since read",
    "tool_use_error",
];

/// Patterns indicating build or lint failures.
pub static BUILD_ERROR_PATTERNS: &[&str] = &[
    "error[e",
    "could not compile",
    "missing_panics_doc",
    "mismatched types",
    "cannot find value",
    "unresolved import",
];

/// Patterns indicating workflow state errors.
pub static WORKFLOW_ERROR_PATTERNS: &[&str] = &[
    "missing active suite",
    "missing suite:",
    "approval state is missing",
    "approval state invalid",
    "runner flow required",
];

/// Phrases indicating user frustration.
pub static USER_FRUSTRATION_SIGNALS: &[&str] = &[
    "don't guess",
    "stop guessing",
    "i already told you",
    "why did you",
    "this is wrong",
    "read it again",
    "i said",
    "that's not what i",
    "no not that",
    "do a solid investigation",
];

/// Signals indicating pod or container failures.
pub static POD_FAILURE_SIGNALS: &[&str] = &[
    "crashloopbackoff",
    "imagepullbackoff",
    "errimagepull",
    "createcontainererror",
    "has been deprecated",
    "decoding failed",
    "cannot unmarshal the configuration",
];

/// Signals indicating auth flow was triggered.
pub static AUTH_SIGNALS: &[&str] = &[
    "if browser window does not open automatically",
    "opening browser for authentication",
    "oauth2",
    "oidc",
    "gcloud auth",
    "az login",
    "aws sso login",
];

/// Signals indicating subagent permission failures.
pub static PERMISSION_SIGNALS: &[&str] = &[
    "i need bash permission",
    "i don't have bash permission",
    "i need write permission",
    "i don't have write permission",
    "permission to run",
    "could you grant",
    "need you to run this command",
];

/// Signals indicating subagent save failures.
pub static SAVE_FAILURE_SIGNALS: &[&str] = &[
    "couldn't save",
    "could not save",
    "failed to save",
    "save it manually",
    "grab its payload",
    "save manually",
    "couldn't persist",
    "failed to persist",
    "completed but couldn't",
    "completed but could not",
    "couldn't write",
    "could not write",
    "let me save its payload",
    "let me extract and save",
];

/// Signals indicating suite deviation.
pub static DEVIATION_SIGNALS: &[&str] = &[
    "deviation from the suite",
    "only exist on",
    "should i apply baselines",
    "not applied to zone",
    "baselines to zone clusters",
    "missing from zone",
];

/// Signals in `AskUserQuestion` indicating runtime deviations.
pub static QUESTION_DEVIATION_SIGNALS: &[&str] = &[
    "deviation",
    "only exist on",
    "should i apply",
    "not found on",
    "missing on",
    "baselines to zone",
    "missing from",
    "not installed",
    "not applied",
    "needs adjustment",
    "need to adjust",
    "ambiguity",
    "records a deviation",
    "this is a deviation",
];

/// Patterns indicating a release kumactl binary is being used instead of a
/// local worktree build. A release version like "kuma 2.13.2" means the
/// system-installed kumactl is on PATH, not the one built from the branch
/// under test.
pub static RELEASE_VERSION_SIGNALS: &[&str] = &["client: kuma 2.", "client: kuma 3."];

/// Patterns indicating python usage in Bash commands.
pub static PYTHON_USAGE_SIGNALS: &[&str] = &["python3 -c", "python -c"];

/// Harness-managed context files that should not be written directly.
pub static MANAGED_CONTEXT_FILES: &[&str] = &[
    "current-run.json",
    "suite-run-state.json",
    "run-status.json",
    "run-report.md",
];

/// Harness operation keywords for detecting manifest failures.
pub static HARNESS_OPERATION_KEYWORDS: &[&str] = &[
    "preflight:",
    "harness preflight",
    "harness apply",
    "harness validate",
    "manifest validation",
    "apply failed",
    "validate failed",
    "admission webhook",
    "denied the request",
    "missing file: manifests/",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ksa_codes_count() {
        assert_eq!(KSA_CODES.len(), 19);
    }

    #[test]
    fn ksa_codes_sequential() {
        for (i, code) in KSA_CODES.iter().enumerate() {
            let expected = format!("ksa{:03}", i + 1);
            assert_eq!(*code, expected);
        }
    }

    #[test]
    fn pattern_slices_non_empty() {
        assert!(!CLI_ERROR_PATTERNS.is_empty());
        assert!(!TOOL_ERROR_PATTERNS.is_empty());
        assert!(!BUILD_ERROR_PATTERNS.is_empty());
        assert!(!WORKFLOW_ERROR_PATTERNS.is_empty());
        assert!(!USER_FRUSTRATION_SIGNALS.is_empty());
        assert!(!POD_FAILURE_SIGNALS.is_empty());
        assert!(!AUTH_SIGNALS.is_empty());
        assert!(!PERMISSION_SIGNALS.is_empty());
        assert!(!SAVE_FAILURE_SIGNALS.is_empty());
        assert!(!DEVIATION_SIGNALS.is_empty());
    }
}

use std::collections::HashMap;
use std::error::Error;
use std::fmt;

use crate::hook::HookResult;

/// Static definition of a CLI error.
#[derive(Debug, Clone)]
pub struct ErrorDef {
    pub code: &'static str,
    pub template: &'static str,
    pub exit_code: i32,
    pub hint: Option<&'static str>,
}

/// Static definition of a hook message.
#[derive(Debug, Clone)]
pub struct HookDef {
    pub code: &'static str,
    pub decision: &'static str,
    pub template: &'static str,
}

/// The unified CLI error type.
#[derive(Debug)]
pub struct CliError {
    pub code: String,
    pub message: String,
    pub exit_code: i32,
    pub hint: Option<String>,
    pub details: Option<String>,
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl Error for CliError {}

/// Construct a `CliError` from a definition and template arguments.
/// Missing placeholders fall back to "?".
#[must_use]
pub fn cli_err(def: &ErrorDef, args: &[(&str, &str)]) -> CliError {
    let map: HashMap<&str, &str> = args.iter().copied().collect();
    let message = render_template(def.template, &map);
    let hint = def.hint.map(|h| render_template(h, &map));
    CliError {
        code: def.code.to_string(),
        message,
        exit_code: def.exit_code,
        hint,
        details: None,
    }
}

/// Construct a `CliError` with details.
#[must_use]
pub fn cli_err_with_details(def: &ErrorDef, args: &[(&str, &str)], details: &str) -> CliError {
    let mut err = cli_err(def, args);
    err.details = Some(details.to_string());
    err
}

/// Construct a `HookResult` from a hook definition and template arguments.
#[must_use]
pub fn hook_msg(def: &HookDef, args: &[(&str, &str)]) -> HookResult {
    let map: HashMap<&str, &str> = args.iter().copied().collect();
    let message = render_template(def.template, &map);
    match def.decision {
        "deny" => HookResult::deny(def.code, &message),
        "warn" => HookResult::warn(def.code, &message),
        _ => HookResult::info(def.code, &message),
    }
}

/// Render a template string with `{field}` placeholders, falling back to "?" for missing keys.
fn render_template(template: &str, args: &HashMap<&str, &str>) -> String {
    let mut result = String::with_capacity(template.len());
    let mut chars = template.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '{' {
            let mut key = String::new();
            let mut closed = false;
            for inner in chars.by_ref() {
                if inner == '}' {
                    closed = true;
                    break;
                }
                key.push(inner);
            }
            if closed {
                if let Some(value) = args.get(key.as_str()) {
                    result.push_str(value);
                } else {
                    result.push('?');
                }
            } else {
                result.push('{');
                result.push_str(&key);
            }
        } else {
            result.push(ch);
        }
    }
    result
}

/// Format a `CliError` for display to stderr.
#[must_use]
pub fn render_error(error: &CliError) -> String {
    let mut lines = vec![format!("ERROR [{}] {}", error.code, error.message)];
    if let Some(hint) = &error.hint {
        lines.push(format!("Hint: {hint}"));
    }
    if let Some(details) = &error.details {
        lines.push("Details:".to_string());
        lines.push(details.clone());
    }
    lines.join("\n")
}

// --- Error definitions ---

pub static EMPTY_COMMAND_ARGS: ErrorDef = ErrorDef {
    code: "KSRCLI001",
    template: "command args must not be empty",
    exit_code: 3,
    hint: None,
};
pub static MISSING_TOOLS: ErrorDef = ErrorDef {
    code: "KSRCLI002",
    template: "missing required tools: {tools}",
    exit_code: 3,
    hint: None,
};
pub static COMMAND_FAILED: ErrorDef = ErrorDef {
    code: "KSRCLI004",
    template: "command failed: {command}",
    exit_code: 4,
    hint: None,
};
pub static MISSING_RUN_POINTER: ErrorDef = ErrorDef {
    code: "KSRCLI005",
    template: "missing current run pointer",
    exit_code: 5,
    hint: Some("Run init first."),
};
pub static MISSING_CLOSEOUT_ARTIFACT: ErrorDef = ErrorDef {
    code: "KSRCLI006",
    template: "missing required closeout artifact: {rel}",
    exit_code: 5,
    hint: None,
};
pub static MISSING_STATE_CAPTURE: ErrorDef = ErrorDef {
    code: "KSRCLI007",
    template: "run is missing a final state capture",
    exit_code: 5,
    hint: None,
};
pub static VERDICT_PENDING: ErrorDef = ErrorDef {
    code: "KSRCLI008",
    template: "run overall verdict is still pending",
    exit_code: 5,
    hint: None,
};
pub static MISSING_RUN_CONTEXT_VALUE: ErrorDef = ErrorDef {
    code: "KSRCLI009",
    template: "missing run context value: {field}",
    exit_code: 5,
    hint: Some("Run `harness init` and the required setup step first."),
};
pub static MISSING_RUN_LOCATION: ErrorDef = ErrorDef {
    code: "KSRCLI018",
    template: "missing explicit run location for run id: {run_id}",
    exit_code: 5,
    hint: Some("Pass `--run-root` or `--run-dir`, or run `harness init` first."),
};
pub static INVALID_JSON: ErrorDef = ErrorDef {
    code: "KSRCLI019",
    template: "invalid JSON in {path}",
    exit_code: 5,
    hint: None,
};
pub static NOT_A_MAPPING: ErrorDef = ErrorDef {
    code: "KSRCLI010",
    template: "{label} must be a mapping",
    exit_code: 5,
    hint: None,
};
pub static NOT_STRING_KEYS: ErrorDef = ErrorDef {
    code: "KSRCLI011",
    template: "{label} must use string keys",
    exit_code: 5,
    hint: None,
};
pub static NOT_A_LIST: ErrorDef = ErrorDef {
    code: "KSRCLI012",
    template: "{label} must be a list",
    exit_code: 5,
    hint: None,
};
pub static NOT_ALL_STRINGS: ErrorDef = ErrorDef {
    code: "KSRCLI013",
    template: "{label} must contain only strings",
    exit_code: 5,
    hint: None,
};
pub static MISSING_FILE: ErrorDef = ErrorDef {
    code: "KSRCLI014",
    template: "missing file: {path}",
    exit_code: 5,
    hint: None,
};
pub static MISSING_FRONTMATTER: ErrorDef = ErrorDef {
    code: "KSRCLI015",
    template: "missing YAML frontmatter",
    exit_code: 5,
    hint: None,
};
pub static UNTERMINATED_FRONTMATTER: ErrorDef = ErrorDef {
    code: "KSRCLI016",
    template: "unterminated YAML frontmatter",
    exit_code: 5,
    hint: None,
};
pub static PATH_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI017",
    template: "path not found: {dotted_path}",
    exit_code: 5,
    hint: None,
};
pub static MISSING_FIELDS: ErrorDef = ErrorDef {
    code: "KSRCLI020",
    template: "missing required fields: {label}: {fields}",
    exit_code: 5,
    hint: None,
};
pub static FIELD_TYPE_MISMATCH: ErrorDef = ErrorDef {
    code: "KSRCLI022",
    template: "field type mismatch in {label}: {field} (expected {expected})",
    exit_code: 5,
    hint: None,
};
pub static MISSING_SECTIONS: ErrorDef = ErrorDef {
    code: "KSRCLI021",
    template: "missing sections: {label}: {sections}",
    exit_code: 5,
    hint: None,
};
pub static NO_RESOURCE_KINDS: ErrorDef = ErrorDef {
    code: "KSRCLI030",
    template: "no resource kinds found in {manifest}",
    exit_code: 5,
    hint: None,
};
pub static ROUTE_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI031",
    template: "route {match} not found",
    exit_code: 5,
    hint: None,
};
pub static GATEWAY_VERSION_MISSING: ErrorDef = ErrorDef {
    code: "KSRCLI032",
    template: "unable to resolve Gateway API version from go.mod",
    exit_code: 5,
    hint: None,
};
pub static GATEWAY_CRDS_MISSING: ErrorDef = ErrorDef {
    code: "KSRCLI033",
    template: "Gateway API CRDs are not installed",
    exit_code: 1,
    hint: None,
};
pub static GATEWAY_DOWNLOAD_EMPTY: ErrorDef = ErrorDef {
    code: "KSRCLI061",
    template: "downloaded Gateway API manifest is empty: {path}",
    exit_code: 5,
    hint: Some("Check the URL and network connectivity."),
};
pub static KUMACTL_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI034",
    template: "unable to find local kumactl",
    exit_code: 5,
    hint: Some("Build kumactl first."),
};
pub static REPORT_LINE_LIMIT: ErrorDef = ErrorDef {
    code: "KSRCLI035",
    template: "report exceeds line limit: {count}>{limit}",
    exit_code: 1,
    hint: None,
};
pub static REPORT_CODE_BLOCK_LIMIT: ErrorDef = ErrorDef {
    code: "KSRCLI036",
    template: "report exceeds code block limit: {count}>{limit}",
    exit_code: 1,
    hint: None,
};
pub static AUTHORING_SESSION_MISSING: ErrorDef = ErrorDef {
    code: "KSRCLI040",
    template: "missing active suite-author authoring session",
    exit_code: 5,
    hint: Some(
        "Run `harness authoring-begin --skill suite-author \
         --repo-root <path> --feature <name> --mode <interactive|bypass> \
         --suite-dir <path> --suite-name <name>` first.",
    ),
};
pub static AUTHORING_PAYLOAD_MISSING: ErrorDef = ErrorDef {
    code: "KSRCLI041",
    template: "missing suite-author payload input",
    exit_code: 5,
    hint: Some(
        "Prefer `--payload <json>` for regular saves. Use `--input <path>` for file-backed \
         payloads. Pipe JSON to stdin only as a last-resort fallback when a regular \
         `--payload` argument is not practical.",
    ),
};
pub static AUTHORING_PAYLOAD_INVALID: ErrorDef = ErrorDef {
    code: "KSRCLI042",
    template: "invalid suite-author {kind} payload: {details}",
    exit_code: 5,
    hint: None,
};
pub static AUTHORING_SHOW_KIND_MISSING: ErrorDef = ErrorDef {
    code: "KSRCLI043",
    template: "missing saved suite-author payload: {kind}",
    exit_code: 5,
    hint: None,
};
pub static AUTHORING_VALIDATE_FAILED: ErrorDef = ErrorDef {
    code: "KSRCLI046",
    template: "suite-author manifest validation failed: {targets}",
    exit_code: 5,
    hint: None,
};
pub static KUBECTL_VALIDATE_DECISION_REQUIRED: ErrorDef = ErrorDef {
    code: "KSRCLI047",
    template: "suite-author local validator decision is still required",
    exit_code: 5,
    hint: None,
};
pub static KUBECTL_VALIDATE_UNAVAILABLE: ErrorDef = ErrorDef {
    code: "KSRCLI048",
    template: "suite-author local validator is unavailable",
    exit_code: 5,
    hint: None,
};
pub static TRACKED_KUBECTL_REQUIRED: ErrorDef = ErrorDef {
    code: "KSRCLI049",
    template: "tracked kubectl command requires an active local cluster kubeconfig",
    exit_code: 5,
    hint: Some("Run `harness init` and `harness cluster ...` first."),
};
pub static KUBECTL_TARGET_OVERRIDE_FORBIDDEN: ErrorDef = ErrorDef {
    code: "KSRCLI050",
    template: "kubectl target override is not allowed in tracked runs: {flag}",
    exit_code: 5,
    hint: Some("Use `harness run --cluster <name> kubectl ...` for another tracked member."),
};
pub static UNKNOWN_TRACKED_CLUSTER: ErrorDef = ErrorDef {
    code: "KSRCLI051",
    template: "unknown tracked cluster member: {cluster}",
    exit_code: 5,
    hint: Some("Use one of: {choices}."),
};
pub static NON_LOCAL_KUBECONFIG: ErrorDef = ErrorDef {
    code: "KSRCLI052",
    template: "tracked kubeconfig is not a local harness cluster: {path}",
    exit_code: 5,
    hint: Some("Recreate the local cluster with `harness cluster ...` before continuing."),
};
pub static RUN_GROUP_ALREADY_RECORDED: ErrorDef = ErrorDef {
    code: "KSRCLI053",
    template: "run group is already recorded: {group_id}",
    exit_code: 5,
    hint: None,
};
pub static RUN_GROUP_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI054",
    template: "group is not present in the run plan: {group_id}",
    exit_code: 5,
    hint: None,
};
pub static ENVOY_CONFIG_TYPE_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI055",
    template: "envoy config type not found: {type_name}",
    exit_code: 5,
    hint: None,
};
pub static ENVOY_CAPTURE_ARGS_REQUIRED: ErrorDef = ErrorDef {
    code: "KSRCLI056",
    template: "envoy live capture requires: {fields}",
    exit_code: 5,
    hint: None,
};
pub static EVIDENCE_LABEL_NOT_FOUND: ErrorDef = ErrorDef {
    code: "KSRCLI057",
    template: "no recorded artifact found for evidence label: {label}",
    exit_code: 5,
    hint: Some("Use `harness record --label <label>` or inspect `commands/command-log.md`."),
};
pub static REPORT_GROUP_EVIDENCE_REQUIRED: ErrorDef = ErrorDef {
    code: "KSRCLI058",
    template: "group report requires at least one evidence input",
    exit_code: 5,
    hint: Some("Pass `--evidence-label <label>` or `--evidence <path>`."),
};
pub static AMENDMENTS_REQUIRED: ErrorDef = ErrorDef {
    code: "KSRCLI045",
    template: "suite amendments entry is missing or empty: {path}",
    exit_code: 5,
    hint: None,
};
pub static RUN_DIR_EXISTS: ErrorDef = ErrorDef {
    code: "KSRCLI044",
    template: "run directory already exists: {run_dir}",
    exit_code: 5,
    hint: Some("Use a new run id or resume the existing run instead of re-running `harness init`."),
};
pub static UNSAFE_NAME: ErrorDef = ErrorDef {
    code: "KSRCLI059",
    template: "unsafe name: {name} (must not contain path separators or \"..\")",
    exit_code: 3,
    hint: None,
};
pub static MISSING_RUN_STATUS: ErrorDef = ErrorDef {
    code: "KSRCLI060",
    template: "run has no recorded status",
    exit_code: 5,
    hint: Some(
        "The run-status.json file could not be loaded. Re-run `harness init` or check the run directory.",
    ),
};
pub static MARKDOWN_SHAPE_MISMATCH: ErrorDef = ErrorDef {
    code: "KSRCLI999",
    template: "markdown row shape mismatch",
    exit_code: 6,
    hint: None,
};

// --- Hook definitions ---

pub static DENY_CLUSTER_BINARY: HookDef = HookDef {
    code: "KSR005",
    decision: "deny",
    template: "Run cluster interactions through `harness run` or another `harness` wrapper.",
};
pub static DENY_ADMIN_ENDPOINT: HookDef = HookDef {
    code: "KSR005",
    decision: "deny",
    template: "Envoy admin calls must go through `harness envoy` or another tracked \
               `harness` wrapper. Prefer one live `harness envoy ...` command over \
               capture-then-read flows.",
};
pub static DENY_MISSING_STATE_CAPTURE: HookDef = HookDef {
    code: "KSR007",
    decision: "deny",
    template: "Run closeout is incomplete: missing final state capture.",
};
pub static DENY_VERDICT_PENDING: HookDef = HookDef {
    code: "KSR007",
    decision: "deny",
    template: "Run closeout is incomplete: verdict is still pending. \
               Run `harness runner-state --event abort` to mark the run as aborted for clean resume later.",
};
pub static DENY_WRITE_OUTSIDE_RUN: HookDef = HookDef {
    code: "KSR008",
    decision: "deny",
    template: "Write path is outside the tracked run surface: {path}",
};
pub static DENY_RUNNER_STATE_INVALID: HookDef = HookDef {
    code: "KSR013",
    decision: "deny",
    template: "Suite-runner state is missing or invalid: {details}",
};
pub static DENY_RUNNER_FLOW_REQUIRED: HookDef = HookDef {
    code: "KSR014",
    decision: "deny",
    template: "Suite-runner phase or approval is required before {action}: {details}",
};
pub static DENY_PREFLIGHT_REPLY_INVALID: HookDef = HookDef {
    code: "KSR015",
    decision: "deny",
    template: "Preflight worker reply is invalid: {details}",
};
pub static DENY_WRITE_OUTSIDE_SUITE: HookDef = HookDef {
    code: "KSA001",
    decision: "deny",
    template: "Write path is outside the suite-author surface: {path}",
};
pub static DENY_APPROVAL_STATE_INVALID: HookDef = HookDef {
    code: "KSA002",
    decision: "deny",
    template: "Suite-author approval state is missing or invalid: {details}",
};
pub static DENY_APPROVAL_REQUIRED: HookDef = HookDef {
    code: "KSA003",
    decision: "deny",
    template: "Suite-author approval is required before {action}: {details}",
};
pub static DENY_GROUPS_NOT_LIST: HookDef = HookDef {
    code: "KSA004",
    decision: "deny",
    template: "suite groups must be a list",
};
pub static DENY_BASELINES_NOT_LIST: HookDef = HookDef {
    code: "KSA004",
    decision: "deny",
    template: "suite baseline_files must be a list",
};
pub static DENY_SUITE_INCOMPLETE: HookDef = HookDef {
    code: "KSA004",
    decision: "deny",
    template: "Suite is incomplete or invalid: {details}",
};
pub static WARN_MISSING_ARTIFACT: HookDef = HookDef {
    code: "KSR006",
    decision: "warn",
    template: "Expected artifact missing after {script}: {target}",
};
pub static WARN_RUN_PREFLIGHT: HookDef = HookDef {
    code: "KSR009",
    decision: "warn",
    template: "Run `harness preflight` before the first cluster mutation.",
};
pub static WARN_PREFLIGHT_MISSING: HookDef = HookDef {
    code: "KSR010",
    decision: "warn",
    template: "Expected preflight artifacts are missing or incomplete.",
};
pub static INFO_SUITE_RUNNER_TRACKED: HookDef = HookDef {
    code: "KSR011",
    decision: "info",
    template: "Suite-runner runs must stay user-story-first and tracked.",
};
pub static INFO_RUN_VERDICT: HookDef = HookDef {
    code: "KSR012",
    decision: "info",
    template: "Current run verdict: {verdict}",
};
pub static WARN_CODE_READER_FORMAT: HookDef = HookDef {
    code: "KSA006",
    decision: "warn",
    template: "Suite-author workers must save structured results through \
               `harness authoring-save` and return only a short acknowledgement.",
};
pub static WARN_READER_MISSING_SECTIONS: HookDef = HookDef {
    code: "KSA007",
    decision: "warn",
    template: "Suite-author worker reply is missing the expected acknowledgement for `{sections}`.",
};
pub static WARN_READER_OVERSIZED_BLOCK: HookDef = HookDef {
    code: "KSA007",
    decision: "warn",
    template: "Suite-author worker reply is oversized; save the structured payload \
               and return a short acknowledgement only.",
};
pub static INFO_SUITE_AUTHOR_TRACKED: HookDef = HookDef {
    code: "KSA008",
    decision: "info",
    template: "Suites must stay user-story-first with concrete variant evidence.",
};
pub static DENY_VALIDATOR_GATE_REQUIRED: HookDef = HookDef {
    code: "KSA009",
    decision: "deny",
    template: "Suite-author local validator decision is required first: {details}",
};
pub static DENY_VALIDATOR_INSTALL_FAILED: HookDef = HookDef {
    code: "KSA010",
    decision: "deny",
    template: "Suite-author local validator install failed: {details}",
};
pub static DENY_VALIDATOR_GATE_UNEXPECTED: HookDef = HookDef {
    code: "KSA011",
    decision: "deny",
    template: "Suite-author local validator gate is not allowed here: {details}",
};

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;
    use crate::hook::Decision;

    // --- CliErr (cli_err) ---

    #[test]
    fn cli_err_basic_fields() {
        let err = cli_err(&NOT_A_MAPPING, &[("label", "foo")]);
        assert_eq!(err.code, "KSRCLI010");
        assert_eq!(err.message, "foo must be a mapping");
        assert_eq!(err.exit_code, 5);
        assert!(err.hint.is_none());
    }

    #[test]
    fn cli_err_with_hint() {
        let err = cli_err(&MISSING_RUN_POINTER, &[]);
        assert_eq!(err.code, "KSRCLI005");
        assert_eq!(err.message, "missing current run pointer");
        assert_eq!(err.hint.as_deref(), Some("Run init first."));
    }

    #[test]
    fn cli_err_with_details_field() {
        let err = cli_err_with_details(&COMMAND_FAILED, &[("command", "ls -la")], "exit 1");
        assert_eq!(err.code, "KSRCLI004");
        assert_eq!(err.message, "command failed: ls -la");
        assert_eq!(err.exit_code, 4);
        assert_eq!(err.details.as_deref(), Some("exit 1"));
    }

    #[test]
    fn cli_err_formats_template() {
        let err = cli_err(&MISSING_FILE, &[("path", "/tmp/gone.txt")]);
        assert_eq!(err.message, "missing file: /tmp/gone.txt");
    }

    #[test]
    fn cli_err_all_codes_unique() {
        let all_defs: &[&ErrorDef] = &[
            &EMPTY_COMMAND_ARGS,
            &MISSING_TOOLS,
            &COMMAND_FAILED,
            &MISSING_RUN_POINTER,
            &MISSING_CLOSEOUT_ARTIFACT,
            &MISSING_STATE_CAPTURE,
            &VERDICT_PENDING,
            &MISSING_RUN_CONTEXT_VALUE,
            &MISSING_RUN_LOCATION,
            &INVALID_JSON,
            &NOT_A_MAPPING,
            &NOT_STRING_KEYS,
            &NOT_A_LIST,
            &NOT_ALL_STRINGS,
            &MISSING_FILE,
            &MISSING_FRONTMATTER,
            &UNTERMINATED_FRONTMATTER,
            &PATH_NOT_FOUND,
            &MISSING_FIELDS,
            &FIELD_TYPE_MISMATCH,
            &MISSING_SECTIONS,
            &NO_RESOURCE_KINDS,
            &ROUTE_NOT_FOUND,
            &GATEWAY_VERSION_MISSING,
            &GATEWAY_CRDS_MISSING,
            &GATEWAY_DOWNLOAD_EMPTY,
            &KUMACTL_NOT_FOUND,
            &REPORT_LINE_LIMIT,
            &REPORT_CODE_BLOCK_LIMIT,
            &AUTHORING_SESSION_MISSING,
            &AUTHORING_PAYLOAD_MISSING,
            &AUTHORING_PAYLOAD_INVALID,
            &AUTHORING_SHOW_KIND_MISSING,
            &AUTHORING_VALIDATE_FAILED,
            &KUBECTL_VALIDATE_DECISION_REQUIRED,
            &KUBECTL_VALIDATE_UNAVAILABLE,
            &TRACKED_KUBECTL_REQUIRED,
            &KUBECTL_TARGET_OVERRIDE_FORBIDDEN,
            &UNKNOWN_TRACKED_CLUSTER,
            &NON_LOCAL_KUBECONFIG,
            &RUN_GROUP_ALREADY_RECORDED,
            &RUN_GROUP_NOT_FOUND,
            &ENVOY_CONFIG_TYPE_NOT_FOUND,
            &ENVOY_CAPTURE_ARGS_REQUIRED,
            &EVIDENCE_LABEL_NOT_FOUND,
            &REPORT_GROUP_EVIDENCE_REQUIRED,
            &AMENDMENTS_REQUIRED,
            &RUN_DIR_EXISTS,
            &UNSAFE_NAME,
            &MISSING_RUN_STATUS,
            &MARKDOWN_SHAPE_MISMATCH,
        ];
        let codes: Vec<&str> = all_defs.iter().map(|d| d.code).collect();
        let unique: HashSet<&str> = codes.iter().copied().collect();
        assert_eq!(codes.len(), unique.len(), "duplicate codes found");
    }

    #[test]
    fn cli_err_no_kwargs_skips_format() {
        let err = cli_err(&MISSING_FRONTMATTER, &[]);
        assert_eq!(err.message, "missing YAML frontmatter");
    }

    #[test]
    fn cli_err_hint_formats_with_kwargs() {
        let err = cli_err(&KUMACTL_NOT_FOUND, &[]);
        assert_eq!(err.hint.as_deref(), Some("Build kumactl first."));
    }

    #[test]
    fn cli_err_report_line_limit() {
        let err = cli_err(&REPORT_LINE_LIMIT, &[("count", "500"), ("limit", "400")]);
        assert_eq!(err.message, "report exceeds line limit: 500>400");
        assert_eq!(err.exit_code, 1);
    }

    #[test]
    fn cli_err_closeout_codes_are_distinct() {
        let codes: HashSet<&str> = [
            MISSING_CLOSEOUT_ARTIFACT.code,
            MISSING_STATE_CAPTURE.code,
            VERDICT_PENDING.code,
        ]
        .into_iter()
        .collect();
        assert_eq!(codes.len(), 3);
    }

    #[test]
    fn cli_err_missing_kwarg_uses_safe_fallback() {
        // template needs {path} but none given
        let err = cli_err(&MISSING_FILE, &[]);
        assert!(err.message.contains('?'));
        assert!(!err.message.contains("{path}"));
    }

    #[test]
    fn cli_err_partial_kwarg_fills_known_marks_unknown() {
        // AUTHORING_PAYLOAD_INVALID needs {kind} and {details}
        let err = cli_err(&AUTHORING_PAYLOAD_INVALID, &[("kind", "schema")]);
        assert!(err.message.contains("schema"));
        assert!(err.message.contains('?'));
        assert!(!err.message.contains("{details}"));
    }

    #[test]
    fn cli_err_markdown_shape_mismatch() {
        let err = cli_err(&MARKDOWN_SHAPE_MISMATCH, &[]);
        assert_eq!(err.code, "KSRCLI999");
        assert_eq!(err.exit_code, 6);
    }

    #[test]
    fn cli_err_display_trait() {
        let err = cli_err(&MISSING_TOOLS, &[("tools", "kubectl")]);
        let displayed = format!("{err}");
        assert_eq!(displayed, "[KSRCLI002] missing required tools: kubectl");
    }

    #[test]
    fn render_error_includes_hint_and_details() {
        let err = CliError {
            code: "X".into(),
            message: "bad".into(),
            exit_code: 1,
            hint: Some("fix it".into()),
            details: Some("stack".into()),
        };
        let rendered = render_error(&err);
        assert!(rendered.contains("ERROR [X] bad"));
        assert!(rendered.contains("Hint: fix it"));
        assert!(rendered.contains("stack"));
    }

    #[test]
    fn render_error_without_hint_or_details() {
        let err = CliError {
            code: "Y".into(),
            message: "oops".into(),
            exit_code: 1,
            hint: None,
            details: None,
        };
        let rendered = render_error(&err);
        assert!(rendered.contains("ERROR [Y] oops"));
        assert!(!rendered.contains("Hint:"));
        assert!(!rendered.contains("Details:"));
    }

    // --- HookMsg (hook_msg) ---

    #[test]
    fn hook_msg_deny_result() {
        let result = hook_msg(&DENY_CLUSTER_BINARY, &[]);
        assert_eq!(result.decision, Decision::Deny);
        assert_eq!(result.code, "KSR005");
        assert!(result.message.contains("`harness run`"));
    }

    #[test]
    fn hook_msg_warn_result() {
        let result = hook_msg(
            &WARN_MISSING_ARTIFACT,
            &[("script", "preflight.py"), ("target", "/tmp/x")],
        );
        assert_eq!(result.decision, Decision::Warn);
        assert_eq!(result.code, "KSR006");
        assert!(result.message.contains("preflight.py"));
        assert!(result.message.contains("/tmp/x"));
    }

    #[test]
    fn hook_msg_info_result() {
        let result = hook_msg(&INFO_RUN_VERDICT, &[("verdict", "pass")]);
        assert_eq!(result.decision, Decision::Info);
        assert_eq!(result.code, "KSR012");
        assert!(result.message.contains("pass"));
    }

    #[test]
    fn hook_msg_deny_with_kwargs() {
        let result = hook_msg(&DENY_WRITE_OUTSIDE_RUN, &[("path", "/bad/path")]);
        assert_eq!(result.decision, Decision::Deny);
        assert!(result.message.contains("/bad/path"));
    }

    #[test]
    fn hook_msg_no_kwargs_skips_format() {
        let result = hook_msg(&DENY_GROUPS_NOT_LIST, &[]);
        assert_eq!(result.message, "suite groups must be a list");
    }

    #[test]
    fn hook_msg_all_decisions_valid() {
        let all_hook_defs: &[&HookDef] = &[
            &DENY_CLUSTER_BINARY,
            &DENY_ADMIN_ENDPOINT,
            &DENY_MISSING_STATE_CAPTURE,
            &DENY_VERDICT_PENDING,
            &DENY_WRITE_OUTSIDE_RUN,
            &DENY_WRITE_OUTSIDE_SUITE,
            &DENY_APPROVAL_STATE_INVALID,
            &DENY_APPROVAL_REQUIRED,
            &DENY_GROUPS_NOT_LIST,
            &DENY_BASELINES_NOT_LIST,
            &DENY_SUITE_INCOMPLETE,
            &WARN_MISSING_ARTIFACT,
            &WARN_RUN_PREFLIGHT,
            &WARN_PREFLIGHT_MISSING,
            &INFO_SUITE_RUNNER_TRACKED,
            &INFO_RUN_VERDICT,
            &WARN_CODE_READER_FORMAT,
            &WARN_READER_MISSING_SECTIONS,
            &WARN_READER_OVERSIZED_BLOCK,
            &INFO_SUITE_AUTHOR_TRACKED,
            &DENY_VALIDATOR_GATE_REQUIRED,
            &DENY_VALIDATOR_INSTALL_FAILED,
            &DENY_VALIDATOR_GATE_UNEXPECTED,
            &DENY_RUNNER_STATE_INVALID,
            &DENY_RUNNER_FLOW_REQUIRED,
            &DENY_PREFLIGHT_REPLY_INVALID,
        ];
        let valid = ["deny", "warn", "info"];
        for def in all_hook_defs {
            assert!(
                valid.contains(&def.decision),
                "{} has invalid decision: {}",
                def.code,
                def.decision
            );
        }
    }

    // --- render_template edge cases ---

    #[test]
    fn render_template_no_placeholders() {
        let map = HashMap::new();
        assert_eq!(render_template("hello world", &map), "hello world");
    }

    #[test]
    fn render_template_all_missing() {
        let map = HashMap::new();
        assert_eq!(render_template("{a} and {b}", &map), "? and ?");
    }

    #[test]
    fn render_template_mixed() {
        let mut map = HashMap::new();
        map.insert("a", "yes");
        assert_eq!(render_template("{a} and {b}", &map), "yes and ?");
    }
}

/// Constants shared between suite-runner and suite-author.
pub mod shared {
    pub const GROUP_REQUIRED_SECTIONS: &[&str] = &["## Configure", "## Consume", "## Debug"];
}

/// Suite-runner constants and phase definitions.
pub mod suite_runner {
    pub const AGENT_PREFLIGHT: &str = "preflight-worker";
    pub const PREFLIGHT_REPLY_HEAD: &str = "suite-runner/preflight:";
    pub const PREFLIGHT_REPLY_PASS: &str = "pass";
    pub const PREFLIGHT_REPLY_FAIL: &str = "fail";

    pub const RUN_STATUS_REQUIRED_FIELDS: &[&str] = &[
        "run_id",
        "suite_id",
        "profile",
        "started_at",
        "completed_at",
        "counts",
        "executed_groups",
        "skipped_groups",
        "last_completed_group",
        "overall_verdict",
        "last_state_capture",
        "last_updated_utc",
        "next_planned_group",
        "notes",
    ];

    pub const REPORT_LINE_LIMIT: usize = 220;
    pub const REPORT_CODE_BLOCK_LIMIT: usize = 4;

    pub const DENIED_LEGACY_SCRIPT_NAMES: &[&str] = &[
        "apply_tracked_manifest.py",
        "capture_state.py",
        "cluster_lifecycle.py",
        "install_gateway_api_crds.py",
        "preflight.py",
        "record_command.py",
        "validate_manifest.py",
    ];

    pub const DENIED_CLUSTER_BINARIES: &[&str] = &["kubectl", "kumactl", "helm", "docker", "k3d"];

    pub const DENIED_ADMIN_ENDPOINT_HINTS: &[&str] = &[
        "localhost:9901",
        "/config_dump",
        "/clusters",
        "/listeners",
        "/routes",
    ];

    pub const ALLOWED_RUN_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "run-metadata.json",
        "current-deploy.json",
        "commands/command-log.md",
        "manifests/manifest-index.md",
    ];

    pub const DIRECT_WRITE_DENIED_RUN_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "suite-runner-state.json",
        "commands/command-log.md",
    ];

    pub const ALLOWED_RUN_DIRS: &[&str] = &["artifacts", "commands", "manifests", "state"];

    pub const HARNESS_MANAGED_RUN_CONTROL_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "suite-runner-state.json",
    ];

    pub const HARNESS_MANAGED_RUN_CONTROL_HINT: &str =
        "use `harness report group`, `harness runner-state`, or `harness closeout`";

    pub const COMMAND_LOG_HINT: &str =
        "use `harness record`, `harness run`, or recorded command artifacts instead";

    pub const DENIED_RUNNER_BINARIES: &[&str] = &["gh"];
    pub const DENIED_MAKE_TARGET_PREFIXES: &[&str] = &["k3d/", "kind/"];

    pub const MANIFEST_FIX_GATE_QUESTION: &str =
        "suite-runner/manifest-fix: how should this failure be handled?";
    pub const MANIFEST_FIX_TARGET_PREFIX: &str = "Suite target: ";
    pub const MANIFEST_FIX_GATE_OPTIONS: &[&str] = &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ];

    // Phases
    pub const PHASE_INITIALIZED: &str = "initialized";
    pub const PHASE_CLUSTER_READY: &str = "cluster_ready";
    pub const PHASE_PREFLIGHT_RUNNING: &str = "preflight_running";
    pub const PHASE_PREFLIGHT_COMPLETE: &str = "preflight_complete";
    pub const PHASE_FAILURE_TRIAGE: &str = "failure_triage";
    pub const PHASE_SUITE_FIX_APPROVED: &str = "suite_fix_approved";
    pub const PHASE_ABORTED: &str = "aborted";

    pub const ALL_PHASES: &[&str] = &[
        PHASE_INITIALIZED,
        PHASE_CLUSTER_READY,
        PHASE_PREFLIGHT_RUNNING,
        PHASE_PREFLIGHT_COMPLETE,
        PHASE_FAILURE_TRIAGE,
        PHASE_SUITE_FIX_APPROVED,
        PHASE_ABORTED,
    ];

    pub const PREWRITE_ALLOWED_PHASES: &[&str] = &[
        PHASE_INITIALIZED,
        PHASE_CLUSTER_READY,
        PHASE_PREFLIGHT_COMPLETE,
        PHASE_FAILURE_TRIAGE,
        PHASE_ABORTED,
    ];

    pub const PREFLIGHT_ALLOWED_SUBCOMMANDS: &[&str] = &["preflight", "capture"];
}

/// Suite-author constants and phase definitions.
pub mod suite_author {
    pub const GROUP_WRITE_PREFIX: &str = "groups/";
    pub const BASELINE_WRITE_PREFIX: &str = "baseline/";
    pub const ALLOWED_WRITE_FILES: &[&str] = &["suite.md"];

    pub const MODE_INTERACTIVE: &str = "interactive";
    pub const MODE_BYPASS: &str = "bypass";
    pub const ALL_MODES: &[&str] = &[MODE_INTERACTIVE, MODE_BYPASS];

    pub const INVENTORY_KIND: &str = "inventory";
    pub const COVERAGE_KIND: &str = "coverage";
    pub const VARIANTS_KIND: &str = "variants";
    pub const SCHEMA_KIND: &str = "schema";
    pub const PROPOSAL_KIND: &str = "proposal";
    pub const EDIT_REQUEST_KIND: &str = "edit-request";

    pub const RESULT_KINDS: &[&str] = &[
        INVENTORY_KIND,
        COVERAGE_KIND,
        VARIANTS_KIND,
        SCHEMA_KIND,
        PROPOSAL_KIND,
        EDIT_REQUEST_KIND,
    ];

    pub const SHOW_KINDS: &[&str] = &[
        "session",
        INVENTORY_KIND,
        COVERAGE_KIND,
        VARIANTS_KIND,
        SCHEMA_KIND,
        PROPOSAL_KIND,
        EDIT_REQUEST_KIND,
    ];

    pub const WORKER_COVERAGE_READER: &str = "coverage-reader";
    pub const WORKER_VARIANT_ANALYZER: &str = "variant-analyzer";
    pub const WORKER_SCHEMA_VERIFIER: &str = "schema-verifier";
    pub const WORKER_SUITE_WRITER: &str = "suite-writer";
    pub const WORKER_BASELINE_WRITER: &str = "baseline-writer";
    pub const WORKER_GROUP_WRITER: &str = "group-writer";

    pub const DISCOVERY_WORKERS: &[&str] = &[
        WORKER_COVERAGE_READER,
        WORKER_VARIANT_ANALYZER,
        WORKER_SCHEMA_VERIFIER,
    ];
    pub const DRAFT_WORKERS: &[&str] = &[
        WORKER_SUITE_WRITER,
        WORKER_BASELINE_WRITER,
        WORKER_GROUP_WRITER,
    ];
    pub const ALL_WORKERS: &[&str] = &[
        WORKER_COVERAGE_READER,
        WORKER_VARIANT_ANALYZER,
        WORKER_SCHEMA_VERIFIER,
        WORKER_SUITE_WRITER,
        WORKER_BASELINE_WRITER,
        WORKER_GROUP_WRITER,
    ];

    pub const VARIANT_STRENGTH_STRONG: &str = "strong";
    pub const VARIANT_STRENGTH_MODERATE: &str = "moderate";
    pub const VARIANT_STRENGTH_WEAK: &str = "weak";
    pub const ALL_VARIANT_STRENGTHS: &[&str] = &[
        VARIANT_STRENGTH_STRONG,
        VARIANT_STRENGTH_MODERATE,
        VARIANT_STRENGTH_WEAK,
    ];

    pub const GATE_PREWRITE: &str = "prewrite";
    pub const GATE_POSTWRITE: &str = "postwrite";
    pub const GATE_COPY: &str = "copy";
    pub const ALLOWED_LAST_GATES: &[&str] = &[GATE_PREWRITE, GATE_POSTWRITE, GATE_COPY];

    // Phases
    pub const PHASE_PREWRITE_PENDING: &str = "prewrite_pending";
    pub const PHASE_PREWRITE_APPROVED: &str = "prewrite_approved";
    pub const PHASE_WRITING_INITIAL: &str = "writing_initial";
    pub const PHASE_POSTWRITE_PENDING: &str = "postwrite_pending";
    pub const PHASE_POSTWRITE_EDITING: &str = "postwrite_editing";
    pub const PHASE_POSTWRITE_APPROVED: &str = "postwrite_approved";
    pub const PHASE_ABORTED: &str = "aborted";
    pub const PHASE_BYPASS: &str = "bypass";

    pub const ALL_PHASES: &[&str] = &[
        PHASE_PREWRITE_PENDING,
        PHASE_PREWRITE_APPROVED,
        PHASE_WRITING_INITIAL,
        PHASE_POSTWRITE_PENDING,
        PHASE_POSTWRITE_EDITING,
        PHASE_POSTWRITE_APPROVED,
        PHASE_ABORTED,
        PHASE_BYPASS,
    ];

    pub const ALL_GATE_QUESTIONS: &[&str] = &[
        PREWRITE_GATE_QUESTION,
        POSTWRITE_GATE_QUESTION,
        COPY_GATE_QUESTION,
    ];

    pub const WRITE_ALLOWED_PHASES: &[&str] = &[
        PHASE_PREWRITE_APPROVED,
        PHASE_WRITING_INITIAL,
        PHASE_POSTWRITE_EDITING,
        PHASE_BYPASS,
    ];

    pub const STOP_ALLOWED_PHASES_AFTER_WRITE: &[&str] =
        &[PHASE_POSTWRITE_APPROVED, PHASE_ABORTED, PHASE_BYPASS];

    pub const PREWRITE_GATE_QUESTION: &str = "suite-author/prewrite: approve current proposal?";
    pub const POSTWRITE_GATE_QUESTION: &str = "suite-author/postwrite: approve saved suite?";
    pub const COPY_GATE_QUESTION: &str = "suite-author/copy: copy run command?";

    pub const PREWRITE_GATE_OPTIONS: &[&str] = &["Approve proposal", "Request changes", "Cancel"];
    pub const POSTWRITE_GATE_OPTIONS: &[&str] = &["Approve suite", "Request changes", "Cancel"];
    pub const COPY_GATE_OPTIONS: &[&str] = &["Copy command", "Skip"];
}

/// Compact/handoff constants.
pub mod compact {
    pub const HANDOFF_VERSION: u32 = 1;
    pub const STATUS_PENDING: &str = "pending";
    pub const STATUS_CONSUMED: &str = "consumed";
    pub const ALL_STATUSES: &[&str] = &[STATUS_PENDING, STATUS_CONSUMED];
    pub const HISTORY_LIMIT: usize = 10;
    pub const SESSION_START_COMPACT: &str = "compact";
    pub const PRECOMPACT_TRIGGER_MANUAL: &str = "manual";
    pub const PRECOMPACT_TRIGGER_AUTO: &str = "auto";
    pub const CHAR_LIMIT: usize = 3500;
    pub const SECTION_CHAR_LIMIT: usize = 1600;
    pub const SECTION_LINE_LIMIT: usize = 25;
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn shared_group_required_sections_count() {
        assert_eq!(shared::GROUP_REQUIRED_SECTIONS.len(), 3);
        assert!(shared::GROUP_REQUIRED_SECTIONS.contains(&"## Configure"));
    }

    #[test]
    fn runner_report_limits() {
        assert_eq!(suite_runner::REPORT_LINE_LIMIT, 220);
        assert_eq!(suite_runner::REPORT_CODE_BLOCK_LIMIT, 4);
    }

    #[test]
    fn runner_denied_cluster_binaries() {
        assert!(suite_runner::DENIED_CLUSTER_BINARIES.contains(&"kubectl"));
        assert!(suite_runner::DENIED_CLUSTER_BINARIES.contains(&"helm"));
        assert_eq!(suite_runner::DENIED_CLUSTER_BINARIES.len(), 5);
    }

    #[test]
    fn runner_all_phases_complete() {
        assert_eq!(suite_runner::ALL_PHASES.len(), 7);
        let set: HashSet<&str> = suite_runner::ALL_PHASES.iter().copied().collect();
        assert!(set.contains("initialized"));
        assert!(set.contains("aborted"));
    }

    #[test]
    fn runner_prewrite_allowed_subset_of_all() {
        let all: HashSet<&str> = suite_runner::ALL_PHASES.iter().copied().collect();
        for phase in suite_runner::PREWRITE_ALLOWED_PHASES {
            assert!(all.contains(phase), "phase {phase} not in ALL_PHASES");
        }
    }

    #[test]
    fn runner_run_status_required_fields() {
        assert_eq!(suite_runner::RUN_STATUS_REQUIRED_FIELDS.len(), 14);
        assert!(suite_runner::RUN_STATUS_REQUIRED_FIELDS.contains(&"run_id"));
        assert!(suite_runner::RUN_STATUS_REQUIRED_FIELDS.contains(&"overall_verdict"));
    }

    #[test]
    fn author_result_kinds() {
        assert_eq!(suite_author::RESULT_KINDS.len(), 6);
        assert!(suite_author::RESULT_KINDS.contains(&"inventory"));
        assert!(suite_author::RESULT_KINDS.contains(&"edit-request"));
    }

    #[test]
    fn author_show_kinds_includes_session() {
        assert!(suite_author::SHOW_KINDS.contains(&"session"));
        assert_eq!(
            suite_author::SHOW_KINDS.len(),
            suite_author::RESULT_KINDS.len() + 1
        );
    }

    #[test]
    fn author_all_workers() {
        assert_eq!(
            suite_author::ALL_WORKERS.len(),
            suite_author::DISCOVERY_WORKERS.len() + suite_author::DRAFT_WORKERS.len()
        );
    }

    #[test]
    fn author_all_phases_complete() {
        assert_eq!(suite_author::ALL_PHASES.len(), 8);
        let set: HashSet<&str> = suite_author::ALL_PHASES.iter().copied().collect();
        assert!(set.contains("prewrite_pending"));
        assert!(set.contains("bypass"));
    }

    #[test]
    fn author_write_allowed_subset_of_all() {
        let all: HashSet<&str> = suite_author::ALL_PHASES.iter().copied().collect();
        for phase in suite_author::WRITE_ALLOWED_PHASES {
            assert!(all.contains(phase), "phase {phase} not in ALL_PHASES");
        }
    }

    #[test]
    fn author_all_modes() {
        assert_eq!(suite_author::ALL_MODES.len(), 2);
    }

    #[test]
    fn author_variant_strengths() {
        assert_eq!(suite_author::ALL_VARIANT_STRENGTHS.len(), 3);
    }

    #[test]
    fn compact_limits() {
        assert_eq!(compact::HANDOFF_VERSION, 1);
        assert_eq!(compact::HISTORY_LIMIT, 10);
        assert_eq!(compact::CHAR_LIMIT, 3500);
    }

    #[test]
    fn compact_all_statuses() {
        assert_eq!(compact::ALL_STATUSES.len(), 2);
        assert!(compact::ALL_STATUSES.contains(&"pending"));
        assert!(compact::ALL_STATUSES.contains(&"consumed"));
    }
}

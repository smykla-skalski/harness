use std::fmt;
use std::str::FromStr;

#[macro_use]
mod skills;
mod gates;

pub use gates::Gate;
pub use skills::{SKILL_NAMES, SKILL_NEW, SKILL_RUN, skill_dirs};

pub use crate::authoring::rules as suite_author;
pub mod suite_runner;

/// Constants shared between suite:run and suite:new.
pub mod shared {
    use super::{FromStr, fmt};

    /// Required markdown sections in a group body.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum GroupSection {
        Configure,
        Consume,
        Debug,
    }

    impl GroupSection {
        pub const ALL: &[Self] = &[Self::Configure, Self::Consume, Self::Debug];

        /// The heading string for this section.
        #[must_use]
        pub const fn as_str(self) -> &'static str {
            match self {
                Self::Configure => "## Configure",
                Self::Consume => "## Consume",
                Self::Debug => "## Debug",
            }
        }

        /// Returns which required sections are absent from `text`.
        #[must_use]
        pub fn missing_from(text: &str) -> Vec<Self> {
            Self::ALL
                .iter()
                .filter(|s| !text.contains(s.as_str()))
                .copied()
                .collect()
        }
    }

    impl fmt::Display for GroupSection {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(self.as_str())
        }
    }

    impl FromStr for GroupSection {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "## Configure" => Ok(Self::Configure),
                "## Consume" => Ok(Self::Consume),
                "## Debug" => Ok(Self::Debug),
                _ => Err(()),
            }
        }
    }
}

/// Compact/handoff constants.
pub mod compact {
    pub const HANDOFF_VERSION: u32 = 1;
    pub const HISTORY_LIMIT: usize = 10;
    pub const CHAR_LIMIT: usize = 3500;
    pub const SECTION_CHAR_LIMIT: usize = 1600;
    pub const SECTION_LINE_LIMIT: usize = 25;
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;

    // Generates all_count, display_roundtrip, and rejects_unknown tests for a string enum.
    macro_rules! test_string_enum {
        ($mod_name:ident, $type:path) => {
            mod $mod_name {
                use super::super::*;
                #[test]
                fn all_count() {
                    assert!(<$type>::ALL.len() > 0);
                }
                #[test]
                fn display_roundtrip() {
                    for v in <$type>::ALL {
                        let parsed: $type = v.to_string().parse().unwrap();
                        assert_eq!(*v, parsed);
                    }
                }
                #[test]
                fn rejects_unknown() {
                    assert!("__invalid__".parse::<$type>().is_err());
                }
            }
        };
    }

    // -- Gate --

    #[test]
    fn gate_matches_exact() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(gate.matches("test?", &["A", "B"]));
    }

    #[test]
    fn gate_rejects_wrong_question() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("other?", &["A", "B"]));
    }

    #[test]
    fn gate_rejects_wrong_options() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("test?", &["A", "C"]));
    }

    #[test]
    fn gate_rejects_wrong_length() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("test?", &["A"]));
    }

    // -- GroupSection --

    test_string_enum!(group_section, shared::GroupSection);

    #[test]
    fn group_section_missing_from() {
        let text = "## Configure\nsome content\n## Debug\nmore content";
        let missing = shared::GroupSection::missing_from(text);
        assert_eq!(missing, vec![shared::GroupSection::Consume]);
    }

    #[test]
    fn group_section_missing_from_none() {
        let text = "## Configure\n## Consume\n## Debug";
        let missing = shared::GroupSection::missing_from(text);
        assert!(missing.is_empty());
    }

    // -- PreflightReply --

    test_string_enum!(preflight_reply, suite_runner::PreflightReply);

    // -- RunFile --

    test_string_enum!(run_file, suite_runner::RunFile);

    #[test]
    fn run_file_is_allowed() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_allowed());
        assert!(RunFile::RunStatus.is_allowed());
        assert!(RunFile::RunMetadata.is_allowed());
        assert!(RunFile::CurrentDeploy.is_allowed());
        assert!(RunFile::CommandLog.is_allowed());
        assert!(RunFile::ManifestIndex.is_allowed());
        assert!(!RunFile::RunnerState.is_allowed());
        assert_eq!(RunFile::ALL.iter().filter(|f| f.is_allowed()).count(), 6);
    }

    #[test]
    fn run_file_is_direct_write_denied() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_direct_write_denied());
        assert!(RunFile::RunStatus.is_direct_write_denied());
        assert!(RunFile::RunnerState.is_direct_write_denied());
        assert!(RunFile::CommandLog.is_direct_write_denied());
        assert!(!RunFile::RunMetadata.is_direct_write_denied());
        assert!(!RunFile::CurrentDeploy.is_direct_write_denied());
        assert!(!RunFile::ManifestIndex.is_direct_write_denied());
        assert_eq!(
            RunFile::ALL
                .iter()
                .filter(|f| f.is_direct_write_denied())
                .count(),
            4
        );
    }

    #[test]
    fn run_file_is_harness_managed() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_harness_managed());
        assert!(RunFile::RunStatus.is_harness_managed());
        assert!(RunFile::RunnerState.is_harness_managed());
        assert!(!RunFile::CommandLog.is_harness_managed());
        assert_eq!(
            RunFile::ALL
                .iter()
                .filter(|f| f.is_harness_managed())
                .count(),
            3
        );
    }

    #[test]
    fn run_file_write_hint() {
        use suite_runner::RunFile;
        assert!(
            RunFile::CommandLog
                .write_hint()
                .contains("harness run record")
        );
        assert!(
            RunFile::RunReport
                .write_hint()
                .contains("harness run report group")
        );
        assert!(
            RunFile::RunnerState
                .write_hint()
                .contains("harness run runner-state")
        );
    }

    // -- RunDir --

    test_string_enum!(run_dir, suite_runner::RunDir);

    // -- LegacyScript --

    test_string_enum!(legacy_script, suite_runner::LegacyScript);

    #[test]
    fn legacy_script_is_denied() {
        assert!(suite_runner::LegacyScript::is_denied("preflight.py"));
        assert!(suite_runner::LegacyScript::is_denied("capture_state.py"));
        assert!(!suite_runner::LegacyScript::is_denied("my_script.py"));
    }

    // -- RunnerBinary --

    test_string_enum!(runner_binary, suite_runner::RunnerBinary);

    #[test]
    fn runner_binary_is_denied() {
        assert!(suite_runner::RunnerBinary::is_denied("gh"));
        assert!(!suite_runner::RunnerBinary::is_denied("git"));
    }

    // -- MakeTargetPrefix --

    test_string_enum!(make_target_prefix, suite_runner::MakeTargetPrefix);

    #[test]
    fn make_target_prefix_is_denied_target() {
        assert!(suite_runner::MakeTargetPrefix::is_denied_target("k3d/stop"));
        assert!(suite_runner::MakeTargetPrefix::is_denied_target(
            "kind/create"
        ));
        assert!(!suite_runner::MakeTargetPrefix::is_denied_target(
            "test/unit"
        ));
    }

    // -- AdminEndpointHint --

    test_string_enum!(admin_endpoint_hint, suite_runner::AdminEndpointHint);

    #[test]
    fn admin_endpoint_hint_contains_hint() {
        assert!(suite_runner::AdminEndpointHint::contains_hint(
            "localhost:9901"
        ));
        assert!(suite_runner::AdminEndpointHint::contains_hint(
            "wget -qO- localhost:9901/config_dump"
        ));
        assert!(!suite_runner::AdminEndpointHint::contains_hint(
            "google.com"
        ));
    }

    // -- TaskOutputPattern --

    test_string_enum!(task_output_pattern, suite_runner::TaskOutputPattern);

    #[test]
    fn task_output_pattern_matches_private_tmp() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat /private/tmp/claude-501/sessions/abc/tasks/xyz.output"
        ));
    }

    #[test]
    fn task_output_pattern_matches_glob() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat tasks/*.output"
        ));
    }

    #[test]
    fn task_output_pattern_matches_b8m() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat tasks/b8m-something"
        ));
    }

    #[test]
    fn task_output_pattern_rejects_unrelated() {
        assert!(!suite_runner::TaskOutputPattern::matches_any(
            "cat /tmp/normal-file.txt"
        ));
    }

    // -- MANIFEST_FIX_GATE --

    #[test]
    fn manifest_fix_gate_options_count() {
        assert_eq!(suite_runner::MANIFEST_FIX_GATE.options.len(), 4);
    }

    #[test]
    fn manifest_fix_gate_matches() {
        let gate = &suite_runner::MANIFEST_FIX_GATE;
        assert!(gate.matches(gate.question, gate.options));
    }

    // -- BUG_FOUND_GATE --

    #[test]
    fn bug_found_gate_options_count() {
        assert_eq!(suite_runner::BUG_FOUND_GATE.options.len(), 3);
    }

    #[test]
    fn bug_found_gate_matches() {
        let gate = &suite_runner::BUG_FOUND_GATE;
        assert!(gate.matches(gate.question, gate.options));
    }

    #[test]
    fn bug_found_gate_question_contains_prefix() {
        assert!(
            suite_runner::BUG_FOUND_GATE
                .question
                .starts_with("suite:run/")
        );
    }

    // -- ResultKind --

    test_string_enum!(result_kind, suite_author::ResultKind);

    // -- Worker --

    test_string_enum!(worker, suite_author::Worker);

    // -- Suite:new gates --

    #[test]
    fn suite_author_gate_questions() {
        assert!(suite_author::PREWRITE_GATE.question.contains("prewrite"));
        assert!(suite_author::POSTWRITE_GATE.question.contains("postwrite"));
        assert!(suite_author::COPY_GATE.question.contains("copy"));
    }

    #[test]
    fn suite_author_gate_options() {
        assert_eq!(suite_author::PREWRITE_GATE.options.len(), 3);
        assert_eq!(suite_author::POSTWRITE_GATE.options.len(), 3);
        assert_eq!(suite_author::COPY_GATE.options.len(), 2);
    }

    // -- Report limits --

    #[test]
    fn report_limits_are_positive() {
        const { assert!(suite_runner::REPORT_LINE_LIMIT > 0) }
        const { assert!(suite_runner::REPORT_CODE_BLOCK_LIMIT > 0) }
        assert_eq!(suite_runner::REPORT_LINE_LIMIT, 220);
        assert_eq!(suite_runner::REPORT_CODE_BLOCK_LIMIT, 4);
    }

    // -- Compact --

    #[test]
    fn compact_constants() {
        assert_eq!(compact::HANDOFF_VERSION, 1);
        assert_eq!(compact::HISTORY_LIMIT, 10);
        assert_eq!(compact::CHAR_LIMIT, 3500);
        assert_eq!(compact::SECTION_CHAR_LIMIT, 1600);
        assert_eq!(compact::SECTION_LINE_LIMIT, 25);
    }

    // -- ControlFileMutationBinary --

    test_string_enum!(
        control_file_mutation_binary,
        suite_runner::ControlFileMutationBinary
    );

    #[test]
    fn control_file_mutation_binary_predicate() {
        assert!(suite_runner::ControlFileMutationBinary::is_mutation_binary(
            "cp"
        ));
        assert!(suite_runner::ControlFileMutationBinary::is_mutation_binary(
            "tee"
        ));
        assert!(!suite_runner::ControlFileMutationBinary::is_mutation_binary("cat"));
    }

    // -- ControlFileReadBinary --

    test_string_enum!(
        control_file_read_binary,
        suite_runner::ControlFileReadBinary
    );

    #[test]
    fn control_file_read_binary_predicate() {
        assert!(suite_runner::ControlFileReadBinary::is_read_binary("cat"));
        assert!(suite_runner::ControlFileReadBinary::is_read_binary("tail"));
        assert!(!suite_runner::ControlFileReadBinary::is_read_binary("cp"));
    }

    // -- SuiteMutationBinary --

    test_string_enum!(suite_mutation_binary, suite_runner::SuiteMutationBinary);

    #[test]
    fn suite_mutation_binary_predicate() {
        assert!(suite_runner::SuiteMutationBinary::is_mutation_binary("rm"));
        assert!(suite_runner::SuiteMutationBinary::is_mutation_binary(
            "touch"
        ));
        assert!(!suite_runner::SuiteMutationBinary::is_mutation_binary(
            "cat"
        ));
    }

    // -- ScriptInterpreter --

    test_string_enum!(script_interpreter, suite_runner::ScriptInterpreter);

    #[test]
    fn script_interpreter_predicate_exact() {
        assert!(suite_runner::ScriptInterpreter::is_interpreter("bash"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("sh"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("zsh"));
    }

    #[test]
    fn script_interpreter_predicate_prefix() {
        assert!(suite_runner::ScriptInterpreter::is_interpreter("node"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("node14"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("python3"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("ruby"));
        assert!(!suite_runner::ScriptInterpreter::is_interpreter("cat"));
    }

    // -- PythonBinary --

    test_string_enum!(python_binary, suite_runner::PythonBinary);

    #[test]
    fn python_binary_predicate() {
        assert!(suite_runner::PythonBinary::is_python("python"));
        assert!(suite_runner::PythonBinary::is_python("python3"));
        assert!(!suite_runner::PythonBinary::is_python("python2"));
    }

    // -- TrackedHarnessSubcommand --

    test_string_enum!(
        tracked_harness_subcommand,
        suite_runner::TrackedHarnessSubcommand
    );

    #[test]
    fn tracked_harness_subcommand_predicate() {
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked("apply"));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked("cli"));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked(
            "init-run"
        ));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked(
            "runner-state"
        ));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked("token"));
        assert!(!suite_runner::TrackedHarnessSubcommand::is_tracked(
            "authoring-show"
        ));
    }

    #[test]
    fn tracked_harness_subcommand_hyphenated_variants() {
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::InitRun.to_string(),
            "init-run"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::RunnerState.to_string(),
            "runner-state"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::SessionStart.to_string(),
            "session-start"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::SessionStop.to_string(),
            "session-stop"
        );
    }
}

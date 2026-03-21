use serde_json::Value;

use crate::observe::patterns;
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCode, MessageRole, ScanState, SourceTool,
};

use super::super::emitter::{Guidance, IssueBlueprint, IssueEmitter};

pub(super) fn check_ask_user_question(
    line_num: usize,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let Some(questions) = input["questions"].as_array() else {
        return;
    };
    let mut emitter = IssueEmitter::new(line_num, MessageRole::Assistant, state);

    for question_block in questions {
        let question_text = question_block["question"].as_str().unwrap_or("");
        let question_lower = question_text.to_lowercase();
        let options = question_block["options"].as_array();
        let header = question_block["header"].as_str().unwrap_or("");

        check_manifest_fix_prompt(question_text, &question_lower, &mut emitter, issues);
        check_validator_install_prompt(question_text, &question_lower, &mut emitter, issues);
        check_question_deviations(
            question_text,
            &question_lower,
            header,
            options,
            &mut emitter,
            issues,
        );
        check_wrong_skill_crossref(
            question_text,
            &question_lower,
            options,
            &mut emitter,
            issues,
        );
    }
}

fn check_manifest_fix_prompt(
    question_text: &str,
    question_lower: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("manifest-fix") && question_lower.contains("how should this failure")
    {
        let details = format!("Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::ManifestFixPromptShown,
                "Manifest rejected by cluster - possible product bug",
            )
            .with_guidance(Guidance::fix_hint(
                "CRD or webhook rejected a manifest. Could be a suite error OR a product bug. Investigate whether the Go validator accepts what the CRD rejects.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::TriageRequired)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
            &details,
        );
    }
}

fn check_validator_install_prompt(
    question_text: &str,
    question_lower: &str,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("kubectl-validate") && question_lower.contains("install") {
        let details = format!("Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::ValidatorInstallPromptShown,
                "Validator install prompt when binary may already exist",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/create/SKILL.md",
                "Step 0 should check if binary exists first",
            ))
            .with_confidence(Confidence::Medium)
            .with_fix_safety(FixSafety::AutoFixGuarded)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
            &details,
        );
    }
}

fn check_question_deviations(
    question_text: &str,
    question_lower: &str,
    header: &str,
    options: Option<&Vec<Value>>,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    let has_signal = |text: &str| -> bool {
        patterns::QUESTION_DEVIATION_SIGNALS
            .iter()
            .any(|signal| text.contains(signal))
    };

    let header_lower = header.to_lowercase();
    let found = has_signal(&header_lower)
        || has_signal(question_lower)
        || options.is_some_and(|opts| {
            opts.iter().any(|opt| {
                opt["label"]
                    .as_str()
                    .is_some_and(|text| has_signal(&text.to_lowercase()))
                    || opt["description"]
                        .as_str()
                        .is_some_and(|text| has_signal(&text.to_lowercase()))
                    || opt
                        .as_str()
                        .is_some_and(|text| has_signal(&text.to_lowercase()))
            })
        });

    if found {
        let details = format!("Header: {header}, Question: {question_text}");
        emitter.emit(
            issues,
            IssueBlueprint::from_code(
                IssueCode::RuntimeDeviationPromptShown,
                "Runtime deviation - authored suite needs runtime correction",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/create/SKILL.md",
                "suite:create should produce suites that don't require runtime deviations",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::TriageRequired)
            .with_source_tool(Some(SourceTool::AskUserQuestion)),
            &details,
        );
    }
}

fn check_wrong_skill_crossref(
    question_text: &str,
    question_lower: &str,
    options: Option<&Vec<Value>>,
    emitter: &mut IssueEmitter<'_>,
    issues: &mut Vec<Issue>,
) {
    let Some(options) = options else {
        return;
    };

    for option in options {
        let label = option["label"]
            .as_str()
            .or_else(|| option.as_str())
            .unwrap_or("");
        if label.to_lowercase().contains("suite:create") && question_lower.contains("suite:run") {
            let details = format!("Question: {question_text}, Option: {label}");
            emitter.emit(
                issues,
                IssueBlueprint::from_code(
                    IssueCode::WrongSkillCrossReference,
                    "suite:run offering suite:create as structured choice",
                )
                .with_guidance(Guidance::fix_target_hint(
                    "skills/run/SKILL.md",
                    "suite:run should not offer suite:create as a structured option",
                ))
                .with_confidence(Confidence::Medium)
                .with_fix_safety(FixSafety::AdvisoryOnly)
                .with_source_tool(Some(SourceTool::AskUserQuestion)),
                &details,
            );
        }
    }
}

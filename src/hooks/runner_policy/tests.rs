use super::{
    classify_canonical_gate, is_install_prompt, is_manifest_fix_prompt,
    matches_kubectl_validate_question, matches_manifest_fix_question,
};
use crate::create::{COPY_GATE, POSTWRITE_GATE, PREWRITE_GATE, ReviewGate};
use crate::hooks::protocol::payloads::{AskUserQuestionOption, AskUserQuestionPrompt};

fn prompt(question: &str, options: &[&str]) -> AskUserQuestionPrompt {
    AskUserQuestionPrompt {
        question: question.to_string(),
        header: None,
        options: options
            .iter()
            .map(|label| AskUserQuestionOption {
                label: (*label).to_string(),
                description: String::new(),
            })
            .collect(),
        multi_select: false,
    }
}

#[test]
fn manifest_fix_prompt_matches_gate() {
    let prompt = prompt(
        "suite:run/manifest-fix: how should this failure be handled?",
        &[
            "Fix for this run only",
            "Fix in suite and this run",
            "Skip this step",
            "Stop run",
        ],
    );
    assert!(is_manifest_fix_prompt(&prompt));
}

#[test]
fn manifest_fix_question_matches_gate() {
    assert!(matches_manifest_fix_question(
        "suite:run/manifest-fix: how should this failure be handled?"
    ));
}

#[test]
fn kubectl_validate_question_matches_install_prompt() {
    assert!(matches_kubectl_validate_question(
        "kubectl-validate install gate"
    ));
}

#[test]
fn install_prompt_detects_kubectl_validate() {
    let prompts = vec![prompt("kubectl-validate install gate", &["Yes", "No"])];
    assert!(is_install_prompt(&prompts));
}

#[test]
fn canonical_gate_classification_matches_create_prompts() {
    let prompts = vec![
        prompt(PREWRITE_GATE.question, PREWRITE_GATE.options),
        prompt(POSTWRITE_GATE.question, POSTWRITE_GATE.options),
        prompt(COPY_GATE.question, COPY_GATE.options),
    ];

    assert_eq!(
        classify_canonical_gate(&prompts),
        Some(ReviewGate::Prewrite)
    );
}

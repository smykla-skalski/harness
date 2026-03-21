use crate::create::{
    COPY_GATE as AUTHOR_COPY_GATE, POSTWRITE_GATE as AUTHOR_POSTWRITE_GATE,
    PREWRITE_GATE as AUTHOR_PREWRITE_GATE, ReviewGate,
};
use crate::hooks::protocol::payloads::AskUserQuestionPrompt;

use super::cluster::MANIFEST_FIX_GATE;

#[must_use]
pub fn is_manifest_fix_prompt(prompt: &AskUserQuestionPrompt) -> bool {
    MANIFEST_FIX_GATE.matches(prompt.question_head(), &prompt.option_labels())
}

#[must_use]
pub fn matches_manifest_fix_question(question: &str) -> bool {
    question == MANIFEST_FIX_GATE.question
}

#[must_use]
pub fn is_install_prompt(prompts: &[AskUserQuestionPrompt]) -> bool {
    prompts
        .iter()
        .any(|prompt| matches_kubectl_validate_question(prompt.question_head()))
}

#[must_use]
pub fn matches_kubectl_validate_question(question: &str) -> bool {
    question.contains("kubectl-validate")
}

#[must_use]
pub fn classify_canonical_gate(prompts: &[AskUserQuestionPrompt]) -> Option<ReviewGate> {
    for prompt in prompts {
        let head = prompt.question_head();
        if head == AUTHOR_PREWRITE_GATE.question {
            return Some(ReviewGate::Prewrite);
        }
        if head == AUTHOR_POSTWRITE_GATE.question {
            return Some(ReviewGate::Postwrite);
        }
        if head == AUTHOR_COPY_GATE.question {
            return Some(ReviewGate::Copy);
        }
    }
    None
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

use super::render_triage_escalation_prompt;
use crate::task_board::prompt_catalog::{
    PROMPT_CATALOG_TEST_LOCK, PromptCatalog, scoped_prompt_catalog,
};
use crate::task_board::types::{TaskBoardItem, TaskBoardItemKind, TaskBoardPriority};

fn item(title: &str, body: &str, tags: Vec<String>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "item-1".into(),
        title.into(),
        body.into(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.tags = tags;
    item.kind = TaskBoardItemKind::Task;
    item.priority = TaskBoardPriority::Medium;
    item
}

#[test]
fn prompt_embeds_item_facts_and_the_exact_report_command() {
    let candidate = item("Vague thing", "some notes", vec!["kind/bug".into()]);

    let prompt = render_triage_escalation_prompt(
        &candidate,
        "triage-escalation-1",
        "token-abc",
        "sha256:fingerprint-1",
    )
    .expect("render escalation prompt");

    assert!(prompt.contains("Vague thing"));
    assert!(prompt.contains("some notes"));
    assert!(prompt.contains("kind/bug"));
    // Pinned through the closing `--rationale` placeholder (not just up to
    // `--fingerprint`) so a spacing or quote-style regression -- in
    // particular the rationale placeholder reverting to double quotes,
    // which would let untrusted, agent-authored rationale text break out
    // via `$(...)`/backticks/backslash in the reporting agent's shell --
    // fails this test.
    assert!(prompt.contains(
        "harness task-board triage-escalation report triage-escalation-1 --token token-abc \
         --fingerprint sha256:fingerprint-1 --verdict <todo|undecided> \
         --rationale '<one sentence, at most 256 bytes, plain text with no quote characters>'"
    ));
    assert!(prompt.contains("untrusted data"));
}

#[test]
fn prompt_handles_empty_body_and_no_tags() {
    let candidate = item("Empty", "", Vec::new());

    let prompt = render_triage_escalation_prompt(
        &candidate,
        "triage-escalation-2",
        "token-xyz",
        "sha256:fingerprint-2",
    )
    .expect("render escalation prompt");

    assert!(prompt.contains("(empty)"));
    assert!(prompt.contains("(none)"));
}

#[test]
fn a_configured_prompt_replaces_the_shipped_one() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let catalog = PromptCatalog::from_json(
        br#"{"triage_escalation": ["Judge {{ title }} ({{ priority }}).", "Report with {{ escalation_id }} and {{ verdict_token }}."]}"#,
    )
    .expect("parse overrides");
    let _installed = scoped_prompt_catalog(catalog);
    let candidate = item("Vague thing", "some notes", Vec::new());

    let prompt =
        render_triage_escalation_prompt(&candidate, "escalation-9", "token-9", "sha256:finger-9")
            .expect("render escalation prompt");

    assert_eq!(
        prompt,
        "Judge Vague thing (Medium).\nReport with escalation-9 and token-9."
    );
}

#[test]
fn a_prompt_naming_an_unknown_variable_fails_before_the_agent_starts() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let catalog = PromptCatalog::from_json(br#"{"triage_escalation": "Judge {{ titel }}"}"#)
        .expect("parse overrides");
    let _installed = scoped_prompt_catalog(catalog);
    let candidate = item("Vague thing", "some notes", Vec::new());

    let error =
        render_triage_escalation_prompt(&candidate, "escalation-9", "token-9", "sha256:finger-9")
            .expect_err("unusable prompt refuses the spawn");

    assert!(error.message().contains("titel"), "{}", error.message());
}

#[test]
fn a_prompt_naming_a_fact_this_item_lacks_fails_before_the_agent_starts() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let catalog =
        PromptCatalog::from_json(br#"{"triage_escalation": "Judge {{ title }} in {{ project_id }}"}"#)
            .expect("parse overrides");
    let _installed = scoped_prompt_catalog(catalog);
    let mut candidate = item("Vague thing", "some notes", Vec::new());

    let error =
        render_triage_escalation_prompt(&candidate, "escalation-9", "token-9", "sha256:finger-9")
            .expect_err("absent fact refuses the spawn");
    assert!(
        error.message().contains("project_id"),
        "{}",
        error.message()
    );

    candidate.project_id = Some("project-7".into());
    let prompt =
        render_triage_escalation_prompt(&candidate, "escalation-9", "token-9", "sha256:finger-9")
            .expect("render escalation prompt");
    assert_eq!(prompt, "Judge Vague thing in project-7");
}

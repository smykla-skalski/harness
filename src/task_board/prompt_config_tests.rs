use std::path::Path;

use crate::feature_flags::{TASK_BOARD_PROMPTS_FILE_ENV, TASK_BOARD_PROMPT_OVERRIDES_ENV};

use super::resolve_prompt_catalog_from_env;

fn write_prompts_file(directory: &Path, body: &str) -> String {
    let path = directory.join("prompts.json");
    fs_err::write(&path, body).expect("write prompt configuration");
    path.to_string_lossy().into_owned()
}

#[test]
fn a_configured_file_is_ignored_while_the_feature_is_off() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = write_prompts_file(directory.path(), r#"{"worker": "Work on {{ title }}"}"#);

    temp_env::with_vars(
        [
            (TASK_BOARD_PROMPT_OVERRIDES_ENV, None),
            (TASK_BOARD_PROMPTS_FILE_ENV, Some(path.as_str())),
        ],
        || assert!(resolve_prompt_catalog_from_env().is_builtin()),
    );
}

#[test]
fn the_feature_without_a_file_keeps_the_builtin_prompts() {
    temp_env::with_vars(
        [
            (TASK_BOARD_PROMPT_OVERRIDES_ENV, Some("1")),
            (TASK_BOARD_PROMPTS_FILE_ENV, None),
        ],
        || assert!(resolve_prompt_catalog_from_env().is_builtin()),
    );
}

#[test]
fn an_unreadable_or_malformed_file_keeps_the_builtin_prompts() {
    let directory = tempfile::tempdir().expect("temp dir");
    let missing = directory.path().join("absent.json");
    let malformed = write_prompts_file(directory.path(), "{ not json");

    for path in [missing.to_string_lossy().into_owned(), malformed] {
        temp_env::with_vars(
            [
                (TASK_BOARD_PROMPT_OVERRIDES_ENV, Some("1")),
                (TASK_BOARD_PROMPTS_FILE_ENV, Some(path.as_str())),
            ],
            || {
                assert!(
                    resolve_prompt_catalog_from_env().is_builtin(),
                    "path {path} should fall back to builtin prompts"
                );
            },
        );
    }
}

#[test]
fn an_enabled_valid_file_customizes_only_the_prompts_it_names() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = write_prompts_file(
        directory.path(),
        r#"{"triage_escalation": ["Decide on {{ title }}", "Tags: {{ tags }}"]}"#,
    );

    temp_env::with_vars(
        [
            (TASK_BOARD_PROMPT_OVERRIDES_ENV, Some("1")),
            (TASK_BOARD_PROMPTS_FILE_ENV, Some(path.as_str())),
        ],
        || {
            let catalog = resolve_prompt_catalog_from_env();
            assert!(!catalog.is_builtin());
            assert_eq!(catalog.customized_prompts(), vec!["triage_escalation"]);
        },
    );
}

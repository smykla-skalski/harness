use std::fs;
use std::path::{Path, PathBuf};

use harness_testkit::with_isolated_harness_env;
use serde_json::json;

use super::*;
use harness_kernel::hooks::context::{
    NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};

fn with_temp_project_without_runtime_ids<F: FnOnce(&Path)>(project_name: &str, test_fn: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg data path")),
                ),
                ("CLAUDE_SESSION_ID", None),
                ("CODEX_SESSION_ID", None),
                ("GEMINI_SESSION_ID", None),
                ("HOME", Some(tmp.path().to_str().expect("home path"))),
            ],
            || {
                let project = tmp.path().join(project_name);
                fs::create_dir_all(&project).expect("create project directory");
                test_fn(&project);
            },
        );
    });
}

#[test]
fn project_dir_for_context_unescapes_shell_escaped_cwd_when_original_path_is_missing() {
    with_temp_project_without_runtime_ids("project@team", |project| {
        let escaped = project.to_string_lossy().replace('@', "\\@");
        let context = NormalizedHookContext {
            event: NormalizedEvent::AgentStop,
            session: SessionContext {
                session_id: "gemini-runtime".into(),
                cwd: Some(PathBuf::from(escaped)),
                transcript_path: None,
            },
            tool: None,
            agent: None,
            skill: SkillContext::inactive(),
            raw: RawPayload::new(json!({})),
        };

        let resolved = project_dir_for_context(&context).expect("resolve project dir");
        assert_eq!(resolved, project);
    });
}

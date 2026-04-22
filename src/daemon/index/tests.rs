use std::path::Path;

use fs_err as fs;
use harness_testkit::{init_git_repo_with_seed, with_isolated_harness_env};
use tempfile::tempdir;

use super::contexts::{infer_checkout_identity, infer_ledger_cwd, repair_context_root};
use super::*;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::{canonical_checkout_root, project_context_dir};

mod adopted_external;
mod repair_context_root;

fn write_text(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent");
    }
    fs::write(path, contents).expect("write file");
}

fn init_git_repo(path: &Path) {
    init_git_repo_with_seed(path);
}

fn write_codex_transcript(context_root: &Path, runtime_session_id: &str) {
    let entries = [
        serde_json::json!({
            "timestamp": "2026-04-14T12:05:00Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"path": "README.md"},
                    "id": "call-1",
                }]
            }
        }),
        serde_json::json!({
            "timestamp": "2026-04-14T12:05:02Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-1",
                    "content": {"line_count": 12},
                    "is_error": false,
                }]
            }
        }),
    ];
    let contents = entries
        .iter()
        .map(|entry| serde_json::to_string(entry).expect("serialize"))
        .collect::<Vec<_>>()
        .join("\n");
    write_text(
        &agent_transcript_path(context_root, "codex", runtime_session_id),
        &contents,
    );
}

#[test]
fn index_round_trip_smoke_covers_public_surface() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("project-alpha");
        init_git_repo(&project_dir);

        temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
            session_service::start_session(
                "Mission control",
                "Keep daemon index queries healthy",
                &project_dir,
                Some("claude"),
                Some("shared-session"),
            )
            .expect("start session");
        });

        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("leader-session")),
                ("CODEX_SESSION_ID", Some("worker-session")),
            ],
            || {
                session_service::join_session(
                    "shared-session",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    &project_dir,
                    None,
                )
                .expect("join session");
            },
        );

        let project = discovered_project_for_checkout(&project_dir);
        let worker_agent_id = load_session_state(&project, "shared-session")
            .expect("load joined state")
            .expect("joined state exists")
            .agents
            .keys()
            .find(|agent_id| agent_id.as_str() != "claude-leader")
            .cloned()
            .expect("worker agent id");
        let task = session_service::create_task(
            "shared-session",
            "Split daemon index",
            Some("exercise public index helpers"),
            crate::session::types::TaskSeverity::High,
            "claude-leader",
            &project_dir,
        )
        .expect("create task");
        session_service::assign_task(
            "shared-session",
            &task.task_id,
            &worker_agent_id,
            "claude-leader",
            &project_dir,
        )
        .expect("assign task");
        let checkpoint = session_service::record_task_checkpoint(
            "shared-session",
            &task.task_id,
            &worker_agent_id,
            "smoke checkpoint",
            70,
            &project_dir,
        )
        .expect("record checkpoint");

        write_codex_transcript(&project.context_root, "worker-session");

        let discovered_projects = discover_projects().expect("discover projects");
        let active_sessions = discover_sessions(false).expect("discover active sessions");
        let per_project_sessions = discover_sessions_for(std::slice::from_ref(&project), true)
            .expect("discover project sessions");
        let resolved = resolve_session("shared-session").expect("resolve session");
        let loaded_state = load_session_state(&project, "shared-session")
            .expect("load state")
            .expect("state exists");
        let log_entries = load_log_entries(&project, "shared-session").expect("load log");
        let checkpoints = load_task_checkpoints(&project, "shared-session", &task.task_id)
            .expect("load checkpoints");
        let conversation_events =
            load_conversation_events(&project, "codex", "worker-session", &worker_agent_id)
                .expect("load conversation events");
        let runtime_session =
            resolve_session_id_for_runtime_session(&project, "codex", "worker-session")
                .expect("resolve runtime session");

        assert_eq!(projects_root(), tmp.path().join("harness/projects"));
        assert_eq!(fast_counts(), (1, 0, 1));
        assert_eq!(project.summary_project_name(), "project-alpha");
        assert_eq!(
            project.summary_project_dir(),
            Some(canonical_checkout_root(&project_dir).display().to_string())
        );
        assert_eq!(
            project.summary_context_root(),
            project.context_root.display().to_string()
        );
        assert_eq!(
            signals_root(&project.context_root),
            project.context_root.join("agents").join("signals")
        );
        assert_eq!(
            agent_transcript_path(&project.context_root, "codex", "worker-session"),
            project
                .context_root
                .join("agents")
                .join("sessions")
                .join("codex")
                .join("worker-session")
                .join("raw.jsonl")
        );
        assert_eq!(
            observe_snapshot_path(&project.context_root, "observe-shared-session"),
            project
                .context_root
                .join("agents")
                .join("observe")
                .join("observe-shared-session")
                .join("snapshot.json")
        );
        assert!(
            discovered_projects
                .iter()
                .any(|candidate| candidate.project_id == project.project_id)
        );
        assert_eq!(active_sessions.len(), 1);
        assert_eq!(per_project_sessions.len(), 1);
        assert_eq!(resolved.state.session_id, "shared-session");
        assert_eq!(loaded_state.session_id, "shared-session");
        assert!(!log_entries.is_empty());
        assert_eq!(checkpoints.len(), 1);
        assert_eq!(checkpoints[0].checkpoint_id, checkpoint.checkpoint_id);
        assert_eq!(conversation_events.len(), 2);
        assert_eq!(runtime_session, Some("shared-session".to_string()));
        assert!(matches!(
            conversation_events[0].kind,
            crate::agents::runtime::event::ConversationEventKind::ToolInvocation {
                ref tool_name,
                ..
            } if tool_name == "Read"
        ));
        assert!(matches!(
            conversation_events[1].kind,
            crate::agents::runtime::event::ConversationEventKind::ToolResult {
                ref tool_name,
                ..
            } if tool_name == "Read"
        ));
    });
}

#[test]
fn infer_checkout_identity_uses_recorded_origin_when_checkout_root_is_missing() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    let project_dir = tmp.path().join("project-name");
    fs::create_dir_all(&project_dir).expect("create project dir");
    write_text(
        &context_root.join("project-origin.json"),
        &serde_json::json!({
            "recorded_from_dir": project_dir.display().to_string(),
            "repository_root": null,
            "checkout_root": null,
            "is_worktree": false,
            "worktree_name": null,
            "recorded_at": "2026-04-10T10:00:00Z",
        })
        .to_string(),
    );

    let identity = infer_checkout_identity(&context_root).expect("identity");

    assert_eq!(identity.repository_root, project_dir);
    assert_eq!(identity.checkout_root, project_dir);
    assert!(!identity.is_worktree);
}

#[test]
fn repair_context_root_prunes_missing_recorded_origin_without_sessions() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    write_text(
        &context_root.join("project-origin.json"),
        &serde_json::json!({
            "recorded_from_dir": tmp.path().join("missing-project").display().to_string(),
            "repository_root": null,
            "checkout_root": null,
            "is_worktree": false,
            "worktree_name": null,
            "recorded_at": "2026-04-10T10:00:00Z",
        })
        .to_string(),
    );

    let repaired = repair_context_root(&context_root).expect("repair context root");

    assert!(repaired.is_none());
    assert!(
        !context_root.exists(),
        "stale context root should be pruned"
    );
}

#[test]
fn fast_counts_ignores_contexts_without_sessions() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_var(
        "XDG_DATA_HOME",
        Some(tmp.path().to_str().expect("utf8 path")),
        || {
            let root = projects_root();
            let stale_context = root.join("project-stale");
            let live_context = root.join("project-live");
            write_text(
                &stale_context.join("project-origin.json"),
                &serde_json::json!({
                    "recorded_from_dir": "/tmp/stale-project",
                    "repository_root": null,
                    "checkout_root": null,
                    "is_worktree": true,
                    "worktree_name": "stale",
                    "recorded_at": "2026-04-10T10:00:00Z",
                })
                .to_string(),
            );
            write_text(
                &live_context.join("project-origin.json"),
                &serde_json::json!({
                    "recorded_from_dir": "/tmp/live-worktree",
                    "repository_root": "/tmp/live-repo",
                    "checkout_root": "/tmp/live-worktree",
                    "is_worktree": true,
                    "worktree_name": "live",
                    "recorded_at": "2026-04-10T10:00:00Z",
                })
                .to_string(),
            );
            fs::create_dir_all(live_context.join("orchestration/sessions/sess-live"))
                .expect("create live session dir");

            let counts = fast_counts();

            assert_eq!(counts, (1, 1, 1));
        },
    );
}

#[test]
fn load_conversation_events_falls_back_to_ledger_for_copilot() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    let ledger_path = context_root.join("agents/ledger/events.jsonl");
    let make_payload = |timestamp: &str, block: serde_json::Value| {
        serde_json::json!({
            "timestamp": timestamp,
            "message": {
                "role": "assistant",
                "content": [block],
            }
        })
    };
    let entries = [
        serde_json::json!({
            "sequence": 1,
            "recorded_at": "2026-03-29T10:00:00Z",
            "agent": "copilot",
            "session_id": "copilot-session-1",
            "skill": "suite",
            "event": "before_tool_use",
            "hook": "tool-guard",
            "decision": "allow",
            "cwd": "/tmp/project",
            "payload": make_payload(
                "2026-03-29T10:00:00Z",
                serde_json::json!({
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"path": "README.md"},
                    "id": "call-1",
                }),
            ),
        }),
        serde_json::json!({
            "sequence": 2,
            "recorded_at": "2026-03-29T10:00:02Z",
            "agent": "copilot",
            "session_id": "copilot-session-1",
            "skill": "suite",
            "event": "after_tool_use",
            "hook": "tool-result",
            "decision": "allow",
            "cwd": "/tmp/project",
            "payload": make_payload(
                "2026-03-29T10:00:02Z",
                serde_json::json!({
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-1",
                    "content": {"line_count": 12},
                    "is_error": false,
                }),
            ),
        }),
    ];
    let contents = entries
        .iter()
        .map(|entry| serde_json::to_string(entry).expect("serialize"))
        .collect::<Vec<_>>()
        .join("\n");
    write_text(&ledger_path, &contents);

    let project = DiscoveredProject {
        project_id: "project-alpha".into(),
        name: "project-alpha".into(),
        project_dir: None,
        repository_root: None,
        checkout_id: "project-alpha".into(),
        checkout_name: "Repository".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };

    let events =
        load_conversation_events(&project, "copilot", "copilot-session-1", "copilot-worker")
            .expect("events");

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[0].agent, "copilot-worker");
    assert_eq!(events[0].session_id, "copilot-session-1");
    assert!(matches!(
        events[0].kind,
        crate::agents::runtime::event::ConversationEventKind::ToolInvocation {
            ref tool_name,
            ..
        } if tool_name == "Read"
    ));
    assert!(matches!(
        events[1].kind,
        crate::agents::runtime::event::ConversationEventKind::ToolResult {
            ref tool_name,
            ..
        } if tool_name == "Read"
    ));
}

#[test]
fn infer_ledger_cwd_uses_last_nonempty_line() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    let ledger_path = context_root.join("agents/ledger/events.jsonl");
    write_text(
        &ledger_path,
        concat!(
            "{\"sequence\":1,\"cwd\":\"/tmp/first\"}\n",
            "{\"sequence\":2,\"cwd\":\"/tmp/second\"}\n\n"
        ),
    );

    let cwd = infer_ledger_cwd(&context_root).expect("cwd");

    assert_eq!(cwd, std::path::PathBuf::from("/tmp/second"));
}

/// Replacement for the Task-8-removed
/// `resolve_runtime_session_uses_context_root_state_instead_of_checkout_storage`:
/// the resolver now takes a `&DiscoveredProject` and must read state from the
/// new layout at `<sessions_root>/<project_name>/<sid>/state.json` scoped to
/// the project bucket.
#[test]
fn resolve_session_id_scopes_to_project_bucket_under_new_layout() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("workspace").join("alpha");
        harness_testkit::init_git_repo_with_seed(&project_dir);

        let session_id = "alphasid";
        let project = discovered_project_for_checkout(&project_dir);
        let layout = crate::session::storage::layout_from_project_dir(&project_dir, session_id)
            .expect("build layout");
        fs::create_dir_all(layout.session_root()).expect("session root");
        let now = "2026-04-20T00:00:00Z";
        let mut state =
            session_service::build_new_session("title", "ctx", session_id, "claude", None, now);
        state
            .agents
            .values_mut()
            .next()
            .expect("leader agent")
            .agent_session_id = Some("runtime-leader-codex".into());
        state
            .agents
            .values_mut()
            .next()
            .expect("leader agent")
            .runtime = "codex".into();
        crate::session::storage::create_state(&layout, &state).expect("write state");
        crate::session::storage::register_active(&layout).expect("register active");

        let resolved =
            resolve_session_id_for_runtime_session(&project, "codex", "runtime-leader-codex")
                .expect("resolve runtime session");
        assert_eq!(resolved.as_deref(), Some(session_id));

        let unrelated_project = discovered_project_for_checkout(&tmp.path().join("unrelated"));
        let unrelated_match = resolve_session_id_for_runtime_session(
            &unrelated_project,
            "codex",
            "runtime-leader-codex",
        )
        .expect("unrelated lookup");
        assert!(
            unrelated_match.is_none(),
            "lookup must be scoped to project bucket"
        );
    });
}

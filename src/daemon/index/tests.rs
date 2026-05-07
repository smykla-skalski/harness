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
mod ledger_fallback;
mod repair_context_root;
mod runtime_sessions;

const SHARED_SESSION_ID: &str = "00000000-0000-4001-8000-000000000001";
const ALPHA_SESSION_ID: &str = "00000000-0000-4001-8000-000000000002";

pub(super) fn write_text(path: &Path, contents: &str) {
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

        let active = temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("77d13b08-1651-541b-a3fc-26cab59e0aea"),
            || {
                let state = session_service::start_session(
                    "Mission control",
                    "Keep daemon index queries healthy",
                    &project_dir,
                    Some(SHARED_SESSION_ID),
                )
                .expect("start session");
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Leader,
                    "claude",
                    &[],
                    None,
                    &project_dir,
                    None,
                )
                .expect("join leader")
            },
        );
        let leader_id = active.leader_id.expect("leader id");

        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("77d13b08-1651-541b-a3fc-26cab59e0aea"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
                ),
            ],
            || {
                session_service::join_session(
                    SHARED_SESSION_ID,
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
        let worker_agent_id = load_session_state(&project, SHARED_SESSION_ID)
            .expect("load joined state")
            .expect("joined state exists")
            .agents
            .keys()
            .find(|agent_id| agent_id.as_str() != leader_id)
            .cloned()
            .expect("worker agent id");
        let task = session_service::create_task(
            SHARED_SESSION_ID,
            "Split daemon index",
            Some("exercise public index helpers"),
            crate::session::types::TaskSeverity::High,
            &leader_id,
            &project_dir,
        )
        .expect("create task");
        session_service::assign_task(
            SHARED_SESSION_ID,
            &task.task_id,
            &worker_agent_id,
            &leader_id,
            &project_dir,
        )
        .expect("assign task");
        let checkpoint = session_service::record_task_checkpoint(
            SHARED_SESSION_ID,
            &task.task_id,
            &worker_agent_id,
            "smoke checkpoint",
            70,
            &project_dir,
        )
        .expect("record checkpoint");

        write_codex_transcript(
            &project.context_root,
            "008d974f-c6a9-53e5-a62e-d331367c449a",
        );

        let discovered_projects = discover_projects().expect("discover projects");
        let active_sessions = discover_sessions(false).expect("discover active sessions");
        let per_project_sessions = discover_sessions_for(std::slice::from_ref(&project), true)
            .expect("discover project sessions");
        let resolved = resolve_session(SHARED_SESSION_ID).expect("resolve session");
        let loaded_state = load_session_state(&project, SHARED_SESSION_ID)
            .expect("load state")
            .expect("state exists");
        let log_entries = load_log_entries(&project, SHARED_SESSION_ID).expect("load log");
        let checkpoints = load_task_checkpoints(&project, SHARED_SESSION_ID, &task.task_id)
            .expect("load checkpoints");
        let conversation_events = load_conversation_events(
            &project,
            "codex",
            "008d974f-c6a9-53e5-a62e-d331367c449a",
            &worker_agent_id,
        )
        .expect("load conversation events");
        let runtime_session = resolve_session_id_for_runtime_session(
            &project,
            "codex",
            "008d974f-c6a9-53e5-a62e-d331367c449a",
        )
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
            agent_transcript_path(
                &project.context_root,
                "codex",
                "008d974f-c6a9-53e5-a62e-d331367c449a"
            ),
            project
                .context_root
                .join("agents")
                .join("sessions")
                .join("codex")
                .join("008d974f-c6a9-53e5-a62e-d331367c449a")
                .join("raw.jsonl")
        );
        let observe_id = format!("observe-{SHARED_SESSION_ID}");
        assert_eq!(
            observe_snapshot_path(&project.context_root, &observe_id),
            project
                .context_root
                .join("agents")
                .join("observe")
                .join(&observe_id)
                .join("snapshot.json")
        );
        assert!(
            discovered_projects
                .iter()
                .any(|candidate| candidate.project_id == project.project_id)
        );
        assert_eq!(active_sessions.len(), 1);
        assert_eq!(per_project_sessions.len(), 1);
        assert_eq!(resolved.state.session_id, SHARED_SESSION_ID);
        assert_eq!(loaded_state.session_id, SHARED_SESSION_ID);
        assert!(!log_entries.is_empty());
        assert_eq!(checkpoints.len(), 1);
        assert_eq!(checkpoints[0].checkpoint_id, checkpoint.checkpoint_id);
        assert_eq!(conversation_events.len(), 2);
        assert_eq!(runtime_session, Some(SHARED_SESSION_ID.to_string()));
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

        let session_id = ALPHA_SESSION_ID;
        temp_env::with_var("CODEX_SESSION_ID", Some("runtime-leader-codex"), || {
            let state =
                session_service::start_session("ctx", "title", &project_dir, Some(session_id))
                    .expect("start session");
            session_service::join_session(
                &state.session_id,
                SessionRole::Leader,
                "codex",
                &[],
                None,
                &project_dir,
                None,
            )
            .expect("join leader");
        });
        let project = discovered_project_for_checkout(&project_dir);

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

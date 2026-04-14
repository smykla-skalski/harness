use std::collections::BTreeSet;
use std::thread;

use fs_err as fs;

use super::*;

fn with_agent_storage_env(body: impl FnOnce(&Path)) {
    let tmp = tempfile::tempdir().unwrap();
    let data_dir = tmp.path().join("xdg_data");
    let project_dir = tmp.path().join("repo");
    fs::create_dir_all(&data_dir).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || body(&project_dir),
    );
}

fn read_ledger_events(project_dir: &Path) -> Vec<AgentLedgerEvent> {
    let ledger = fs::read_to_string(ledger_path(project_dir)).unwrap();
    ledger
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str::<AgentLedgerEvent>(line).unwrap())
        .collect()
}

fn read_sequence_state(project_dir: &Path) -> LedgerSequenceState {
    read_json_typed(&ledger_sequence_path(project_dir)).unwrap()
}

fn read_session_lines(project_dir: &Path, agent: HookAgent, session_id: &str) -> Vec<String> {
    fs::read_to_string(session_file_path(project_dir, agent, session_id))
        .unwrap()
        .lines()
        .map(ToOwned::to_owned)
        .collect()
}

#[test]
fn append_session_marker_bootstraps_sequence_state_from_existing_ledger() {
    with_agent_storage_env(|project_dir| {
        append_session_marker(project_dir, HookAgent::Codex, "codex-a", "session_start").unwrap();
        fs::remove_file(ledger_sequence_path(project_dir)).unwrap();

        append_session_marker(project_dir, HookAgent::Codex, "codex-a", "session_stop").unwrap();

        let events = read_ledger_events(project_dir);
        let sequences: Vec<u64> = events.iter().map(|event| event.sequence).collect();
        assert_eq!(sequences, vec![1, 2]);
        assert_eq!(read_sequence_state(project_dir).last_sequence, 2);
    });
}

#[test]
fn concurrent_multi_agent_writes_assign_unique_sequences() {
    with_agent_storage_env(|project_dir| {
        thread::scope(|scope| {
            for (agent, session_id) in [
                (HookAgent::Claude, "claude-a"),
                (HookAgent::Codex, "codex-a"),
                (HookAgent::Gemini, "gemini-a"),
                (HookAgent::Copilot, "copilot-a"),
            ] {
                scope.spawn(move || {
                    for _ in 0..8 {
                        append_session_marker(project_dir, agent, session_id, "session_start")
                            .unwrap();
                    }
                });
            }
        });

        let events = read_ledger_events(project_dir);
        assert_eq!(events.len(), 32);

        let sequences: BTreeSet<u64> = events.iter().map(|event| event.sequence).collect();
        assert_eq!(sequences.len(), events.len());
        assert_eq!(sequences.first().copied(), Some(1));
        assert_eq!(sequences.last().copied(), Some(32));
        assert_eq!(read_sequence_state(project_dir).last_sequence, 32);

        for (agent, session_id) in [
            (HookAgent::Claude, "claude-a"),
            (HookAgent::Codex, "codex-a"),
            (HookAgent::Gemini, "gemini-a"),
            (HookAgent::Copilot, "copilot-a"),
        ] {
            assert_eq!(read_session_lines(project_dir, agent, session_id).len(), 8);
        }
    });
}

#[test]
fn session_registry_keeps_agent_pointers_independent() {
    with_agent_storage_env(|project_dir| {
        thread::scope(|scope| {
            for (agent, session_id) in [
                (HookAgent::Claude, "claude-current"),
                (HookAgent::Codex, "codex-current"),
                (HookAgent::Gemini, "gemini-current"),
                (HookAgent::Copilot, "copilot-current"),
            ] {
                scope.spawn(move || {
                    set_current_session_id(project_dir, agent, session_id).unwrap();
                });
            }
        });

        assert_eq!(
            current_session_id(project_dir, HookAgent::Claude)
                .unwrap()
                .as_deref(),
            Some("claude-current")
        );
        assert_eq!(
            current_session_id(project_dir, HookAgent::Codex)
                .unwrap()
                .as_deref(),
            Some("codex-current")
        );
        assert_eq!(
            current_session_id(project_dir, HookAgent::Gemini)
                .unwrap()
                .as_deref(),
            Some("gemini-current")
        );
        assert_eq!(
            current_session_id(project_dir, HookAgent::Copilot)
                .unwrap()
                .as_deref(),
            Some("copilot-current")
        );

        clear_current_session_id(project_dir, HookAgent::Codex).unwrap();

        assert_eq!(
            current_session_id(project_dir, HookAgent::Codex).unwrap(),
            None
        );
        assert_eq!(
            current_session_id(project_dir, HookAgent::Claude)
                .unwrap()
                .as_deref(),
            Some("claude-current")
        );
        assert_eq!(
            current_session_id(project_dir, HookAgent::Copilot)
                .unwrap()
                .as_deref(),
            Some("copilot-current")
        );
    });
}

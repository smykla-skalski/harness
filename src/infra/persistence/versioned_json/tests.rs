use std::fs;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use super::*;
use serde_json::json;
use tempfile::TempDir;

#[test]
fn load_returns_none_when_file_missing() {
    let dir = TempDir::new().unwrap();
    let repo = VersionedJsonRepository::<Value>::new(dir.path().join("state.json"), 1);
    assert!(repo.load().unwrap().is_none());
}

#[test]
fn save_and_load_round_trip() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path, 1);
    let state = json!({"schema_version": 1, "phase": "bootstrap"});
    repo.save(&state).unwrap();
    let loaded = repo.load().unwrap().unwrap();
    assert_eq!(loaded["phase"], "bootstrap");
}

#[test]
fn load_rejects_wrong_version() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path.clone(), 2);
    let state = json!({"schema_version": 99, "phase": "bootstrap"});
    fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
    let err = repo.load().unwrap_err();
    assert!(err.message().contains("unsupported"));
}

#[test]
fn load_migrates_older_version_and_resaves() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo =
        VersionedJsonRepository::<Value>::new(path.clone(), 2).with_migrations(vec![Box::new(
            |value| {
                Ok(json!({
                    "schema_version": 2,
                    "state": {
                        "phase": value["phase"].clone(),
                    },
                }))
            },
        )]);
    let state = json!({"schema_version": 1, "phase": "bootstrap"});
    fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

    let loaded = repo.load().unwrap().unwrap();
    assert_eq!(loaded["schema_version"], 2);
    assert_eq!(loaded["state"]["phase"], "bootstrap");

    let on_disk: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(on_disk["schema_version"], 2);
    assert_eq!(on_disk["state"]["phase"], "bootstrap");
}

#[test]
fn load_skips_migration_when_version_matches() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let migration_calls = Arc::new(AtomicUsize::new(0));
    let repo =
        VersionedJsonRepository::<Value>::new(path.clone(), 2).with_migrations(vec![Box::new({
            let migration_calls = Arc::clone(&migration_calls);
            move |value| {
                migration_calls.fetch_add(1, Ordering::Relaxed);
                Ok(value)
            }
        })]);
    let state = json!({"schema_version": 2, "phase": "bootstrap"});
    fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

    let loaded = repo.load().unwrap().unwrap();
    assert_eq!(loaded["phase"], "bootstrap");
    assert_eq!(migration_calls.load(Ordering::Relaxed), 0);
}

#[test]
fn load_supports_migration_chains() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path.clone(), 3).with_migrations(vec![
        Box::new(|value| {
            Ok(json!({
                "schema_version": 2,
                "phase": value["phase"].clone(),
                "preflight": { "status": "pending" },
            }))
        }),
        Box::new(|value| {
            Ok(json!({
                "schema_version": 3,
                "state": {
                    "phase": value["phase"].clone(),
                    "preflight": value["preflight"].clone(),
                },
            }))
        }),
    ]);
    let state = json!({"schema_version": 1, "phase": "bootstrap"});
    fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

    let loaded = repo.load().unwrap().unwrap();
    assert_eq!(loaded["schema_version"], 3);
    assert_eq!(loaded["state"]["phase"], "bootstrap");
    assert_eq!(loaded["state"]["preflight"]["status"], "pending");
}

#[test]
fn save_creates_parent_directories() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("nested").join("dir").join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path, 1);
    let state = json!({"schema_version": 1});
    repo.save(&state).unwrap();
    assert!(repo.path.exists());
}

#[test]
fn save_is_atomic_via_rename() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path, 1);
    let state = json!({"schema_version": 1, "data": "first"});
    repo.save(&state).unwrap();
    let state2 = json!({"schema_version": 1, "data": "second"});
    repo.save(&state2).unwrap();
    let loaded = repo.load().unwrap().unwrap();
    assert_eq!(loaded["data"], "second");
}

#[test]
fn update_serializes_concurrent_writers() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let initial = json!({"schema_version": 1, "count": 0});
    VersionedJsonRepository::<Value>::new(path.clone(), 1)
        .save(&initial)
        .unwrap();

    let mut workers = Vec::new();
    for _ in 0..8 {
        let path = path.clone();
        workers.push(thread::spawn(move || {
            let repo = VersionedJsonRepository::<Value>::new(path, 1);
            for _ in 0..25 {
                repo.update(|current| {
                    let mut next =
                        current.unwrap_or_else(|| json!({"schema_version": 1, "count": 0}));
                    let count = next["count"].as_u64().unwrap();
                    next["count"] = json!(count + 1);
                    Ok(Some(next))
                })
                .unwrap();
            }
        }));
    }

    for worker in workers {
        worker.join().unwrap();
    }

    let loaded = VersionedJsonRepository::<Value>::new(path, 1)
        .load()
        .unwrap()
        .unwrap();
    assert_eq!(loaded["count"], 200);
}

#[test]
fn update_skips_rewrite_when_state_is_unchanged() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("state.json");
    let repo = VersionedJsonRepository::<Value>::new(path.clone(), 1);
    let state = json!({"schema_version": 1, "phase": "steady"});
    repo.save(&state).unwrap();

    let before = fs::metadata(&path).unwrap().modified().unwrap();
    thread::sleep(Duration::from_millis(20));

    let updated = repo.update(|current| Ok(current)).unwrap().unwrap();

    let after = fs::metadata(&path).unwrap().modified().unwrap();
    assert_eq!(updated, state);
    assert_eq!(before, after);
}

#[test]
fn transition_error_displays_message() {
    let err = TransitionError("bad transition".to_string());
    assert_eq!(err.to_string(), "bad transition");
}

#[test]
fn path_accessor_returns_configured_path() {
    let repo = VersionedJsonRepository::<Value>::new(PathBuf::from("/tmp/test.json"), 3);
    assert_eq!(repo.path(), Path::new("/tmp/test.json"));
    assert_eq!(repo.current_version(), 3);
}

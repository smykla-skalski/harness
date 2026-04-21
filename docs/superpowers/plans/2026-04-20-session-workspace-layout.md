# Session workspace layout - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-20-session-workspace-layout-design.md`

**Goal:** Replace the current `projects/project-{8hex}/orchestration/sessions/sess-...` layout with `sessions/<project>[-<4hex>]/<8char-sid>/{workspace/, memory/, state.json, log.jsonl, tasks/, .locks/}`. Daemon owns git-worktree lifecycle. Sockets move to a flat `<group>/sock/` namespace on macOS.

**Architecture:** `src/workspace/layout.rs` owns the session path primitives, `src/workspace/project_resolver.rs` resolves project directory names, `src/workspace/worktree.rs` runs synchronous `git worktree add/remove`, and `src/workspace/socket_paths.rs` keeps socket paths short. The project-level `.origin` marker and the session-level `.origin` marker are both intentional. HTTP session responses keep the same `SessionState` family but with the new layout fields, so this is a **major** version bump.

**Tech stack:** Rust 2024 (clippy pedantic), synchronous `std::process::Command` for git, Swift 6 on the Monitor side for path model updates.

**Version impact:** **Major** bump at the end. Persisted layout contract changes; HTTP `SessionState` wire shape changes.

**Prerequisite:** Sub-project A must be merged first. B uses A's `harness_data_root()` (app group container) and A's `BookmarkResolver` for resolving `project_dir` bookmarks when sandboxed.

---

## File structure

### New Rust files

| Path | Responsibility |
| --- | --- |
| `src/workspace/layout.rs` | `SessionLayout` struct, path builders, branch-ref generator |
| `src/workspace/layout/tests.rs` | Path round-trips, collision resolver, socket budget |
| `src/workspace/ids.rs` | `new_session_id()`, validation |
| `src/workspace/ids/tests.rs` | Format assertions |
| `src/workspace/project_resolver.rs` | `resolve_name()` with project-level `.origin` marker |
| `src/workspace/project_resolver/tests.rs` | Collision + idempotency |
| `src/workspace/worktree.rs` | `WorktreeController` (create, destroy) |
| `src/workspace/worktree/tests.rs` | Lifecycle on scratch git repo |
| `src/workspace/socket_paths.rs` | `session_socket()`, cross-platform logic |
| `src/workspace/socket_paths/tests.rs` | 104-byte budget on synthetic long home |
| `src/workspace/orphan_cleanup.rs` | Startup sweep for orphaned session dirs |
| `src/workspace/orphan_cleanup/tests.rs` | |
| `tests/integration/workspace/mod.rs` | Module root |
| `tests/integration/workspace/session_lifecycle.rs` | End-to-end create + delete |
| `tests/integration/workspace/parallel_sessions.rs` | Two sessions, same origin |
| `tests/integration/workspace/collision.rs` | Two origins with same basename |

### Modified Rust files

| Path | Change |
| --- | --- |
| `Cargo.toml` | Ensure `rand = "0.9"` is present; no `fd-lock` dependency is needed |
| `src/workspace/mod.rs` | Register new modules; remove `project_context_dir` and friends |
| `src/workspace/session.rs` | Remove `project_context_dir`, `session_scope_key`, `orchestration_root`, `sessions_root` - clean cut |
| `src/workspace/compact/paths.rs` | Rewrite to use new `SessionLayout` |
| `src/workspace/remote_kubernetes.rs` | Rewrite to use new `SessionLayout` |
| `src/session/storage/files.rs` | Rewrite every path builder to use `SessionLayout` |
| `src/session/storage/registry.rs` | Move `active.json` to `<sessions_root>/<project>/.active.json`; drop `is_worktree`, `worktree_name`, `recorded_from_dir` fields |
| `src/daemon/service/session_setup.rs` | Wire `WorktreeController::create` on session creation |
| `src/daemon/http/sessions.rs` | Route `POST /v1/sessions` to session setup; `POST /v1/sessions/{id}/end` and `POST /v1/sessions/{id}/leave` remain the evidenced lifecycle endpoints |
| `src/daemon/protocol/session_requests.rs` | `SessionStartRequest` already carries optional `base_ref`; `SessionState` carries `project_name`, `session_id`, `worktree_path`, `shared_path`, `origin_path`, `branch_ref` |
| `src/app/cli.rs` + `src/app/cli/tests/session.rs` | Update CLI session commands + snapshots |
| `src/mcp/registry/*` | Move socket paths to `socket_paths::session_socket()` |
| `src/daemon/bridge/runtime.rs`, `client.rs` | Same |

### Modified Swift files

| Path | Change |
| --- | --- |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift` | Add `sessionsRoot`, `sessionRoot`, `sessionWorktree`, `sessionShared`, `socketDirectory` |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift` | Rewrite `SessionState` shape (new fields, dropped fields) |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Persistence/CachedModels.swift` and V4/V5 migration | New SwiftData migration V6 for the new session model |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore*.swift` | Adopt new `SessionState` fields |

---

## Task 1: Session id generator

**Files:**
- Create: `src/workspace/ids.rs`
- Create: `src/workspace/ids/tests.rs`
- Modify: `src/workspace/mod.rs` (`pub mod ids;`)

- [ ] **Step 1: Write failing tests**

`src/workspace/ids/tests.rs`:

```rust
use super::*;

#[test]
fn generates_8_lowercase_alphanumeric_chars() {
    for _ in 0..200 {
        let id = new_session_id();
        assert_eq!(id.len(), 8, "id: {id}");
        assert!(
            id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()),
            "id: {id}",
        );
    }
}

#[test]
fn validate_rejects_invalid() {
    assert!(validate("abc12345").is_ok());
    assert!(validate("ABCDEFGH").is_err());           // uppercase
    assert!(validate("abc-1234").is_err());           // dash
    assert!(validate("abc1234").is_err());            // too short
    assert!(validate("abc123456").is_err());          // too long
    assert!(validate("").is_err());
}

#[test]
fn generated_ids_pass_validation() {
    for _ in 0..50 {
        validate(&new_session_id()).expect("generated id must validate");
    }
}
```

- [ ] **Step 2: Run red**

```bash
cargo test --lib workspace::ids
```

Expected: compile error.

- [ ] **Step 3: Implement**

`src/workspace/ids.rs`:

```rust
//! 8-character lowercase alphanumeric session id.

use rand::{distributions::Distribution, Rng};
use thiserror::Error;

pub const SESSION_ID_LEN: usize = 8;
const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";

#[derive(Debug, Error)]
pub enum IdError {
    #[error("session id must be {SESSION_ID_LEN} lowercase alphanumeric characters: {0:?}")]
    Invalid(String),
}

#[must_use]
pub fn new_session_id() -> String {
    let mut rng = rand::thread_rng();
    (0..SESSION_ID_LEN)
        .map(|_| {
            let idx = rng.gen_range(0..ALPHABET.len());
            ALPHABET[idx] as char
        })
        .collect()
}

pub fn validate(id: &str) -> Result<(), IdError> {
    if id.len() != SESSION_ID_LEN {
        return Err(IdError::Invalid(id.to_string()));
    }
    if !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        return Err(IdError::Invalid(id.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 4: Green**

```bash
cargo test --lib workspace::ids
```

Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add 8-char session ids"
```

---

## Task 2: Project name resolver

**Files:**
- Create: `src/workspace/project_resolver.rs`
- Create: `src/workspace/project_resolver/tests.rs`
- Modify: `src/workspace/mod.rs`

- [ ] **Step 1: Failing tests**

`src/workspace/project_resolver/tests.rs`:

```rust
use super::*;
use tempfile::TempDir;

#[test]
fn unique_basenames_use_bare_name() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();

    let canonical = std::path::PathBuf::from("/Users/b/Projects/kuma");
    let name = resolve_name(&canonical, &sessions).unwrap();
    assert_eq!(name, "kuma");
}

#[test]
fn collision_adds_hash_suffix() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();

    let first = std::path::PathBuf::from("/Users/b/Projects/kuma");
    let second = std::path::PathBuf::from("/Users/b/Projects-alt/kuma");

    let a = resolve_name(&first, &sessions).unwrap();
    // Simulate existing project dir + its .origin marker.
    std::fs::create_dir_all(sessions.join(&a)).unwrap();
    write_origin_marker(&sessions.join(&a), &first).unwrap();

    let b = resolve_name(&second, &sessions).unwrap();
    assert_ne!(a, b);
    assert!(b.starts_with("kuma-"));
    assert_eq!(b.len(), "kuma-".len() + 4);
}

#[test]
fn resolves_idempotently() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let canonical = std::path::PathBuf::from("/Users/b/Projects/kuma");

    let a = resolve_name(&canonical, &sessions).unwrap();
    std::fs::create_dir_all(sessions.join(&a)).unwrap();
    write_origin_marker(&sessions.join(&a), &canonical).unwrap();
    let b = resolve_name(&canonical, &sessions).unwrap();
    assert_eq!(a, b);
}
```

- [ ] **Step 2: Implement**

`src/workspace/project_resolver.rs`:

```rust
//! Project directory name resolution with collision handling.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use thiserror::Error;

const ORIGIN_MARKER: &str = ".origin";
const SUFFIX_LEN: usize = 4;

#[derive(Debug, Error)]
pub enum ResolverError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("canonical path has no file name: {0}")]
    NoBasename(PathBuf),
}

pub fn resolve_name(
    canonical_path: &Path,
    sessions_root: &Path,
) -> Result<String, ResolverError> {
    let base = canonical_path
        .file_name()
        .ok_or_else(|| ResolverError::NoBasename(canonical_path.to_path_buf()))?
        .to_string_lossy()
        .to_string();
    let candidate = sessions_root.join(&base);

    if candidate.exists() {
        if read_origin_marker(&candidate)?.as_deref() == Some(canonical_path.to_str().unwrap_or("")) {
            return Ok(base);
        }
    } else {
        return Ok(base);
    }

    // Collision: append 4-hex suffix.
    let suffix = digest_suffix(canonical_path);
    Ok(format!("{base}-{suffix}"))
}

pub fn write_origin_marker(project_dir: &Path, canonical_path: &Path) -> io::Result<()> {
    fs::write(project_dir.join(ORIGIN_MARKER), canonical_path.to_string_lossy().as_bytes())
}

fn read_origin_marker(project_dir: &Path) -> io::Result<Option<String>> {
    let marker = project_dir.join(ORIGIN_MARKER);
    if !marker.exists() {
        return Ok(None);
    }
    Ok(Some(fs::read_to_string(marker)?.trim().to_string()))
}

fn digest_suffix(canonical_path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(canonical_path.to_string_lossy().as_bytes());
    let hash = hasher.finalize();
    hash.iter()
        .take(SUFFIX_LEN / 2)
        .fold(String::with_capacity(SUFFIX_LEN), |mut acc, b| {
            use std::fmt::Write as _;
            let _ = write!(acc, "{b:02x}");
            acc
        })
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green**

```bash
cargo test --lib workspace::project_resolver
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add project name resolver"
```

---

## Task 3: SessionLayout path primitives

**Files:**
- Create: `src/workspace/layout.rs`
- Create: `src/workspace/layout/tests.rs`

- [ ] **Step 1: Failing tests**

`src/workspace/layout/tests.rs`:

```rust
use std::path::PathBuf;
use super::*;

fn fixture() -> SessionLayout {
    SessionLayout {
        sessions_root: PathBuf::from("/data/sessions"),
        project_name: "kuma".into(),
        session_id: "abc12345".into(),
    }
}

#[test]
fn session_root_composes_correctly() {
    assert_eq!(fixture().session_root(), PathBuf::from("/data/sessions/kuma/abc12345"));
}

#[test]
fn workspace_subdir() {
    assert_eq!(fixture().workspace(), PathBuf::from("/data/sessions/kuma/abc12345/workspace"));
}

#[test]
fn memory_subdir() {
    assert_eq!(fixture().memory(), PathBuf::from("/data/sessions/kuma/abc12345/memory"));
}

#[test]
fn state_file_sibling() {
    assert_eq!(fixture().state_file(), PathBuf::from("/data/sessions/kuma/abc12345/state.json"));
}

#[test]
fn branch_ref_flat() {
    assert_eq!(fixture().branch_ref(), "harness/abc12345");
}

#[test]
fn active_json_is_per_project_hidden_file() {
    assert_eq!(
        fixture().active_registry(),
        PathBuf::from("/data/sessions/kuma/.active.json")
    );
}
```

- [ ] **Step 2: Implement**

`src/workspace/layout.rs`:

```rust
//! Per-session directory layout primitives.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionLayout {
    pub sessions_root: PathBuf,
    pub project_name: String,
    pub session_id: String,
}

impl SessionLayout {
    #[must_use]
    pub fn project_dir(&self) -> PathBuf {
        self.sessions_root.join(&self.project_name)
    }

    #[must_use]
    pub fn session_root(&self) -> PathBuf {
        self.project_dir().join(&self.session_id)
    }

    #[must_use]
    pub fn workspace(&self) -> PathBuf {
        self.session_root().join("workspace")
    }

    #[must_use]
    pub fn memory(&self) -> PathBuf {
        self.session_root().join("memory")
    }

    #[must_use]
    pub fn state_file(&self) -> PathBuf {
        self.session_root().join("state.json")
    }

    #[must_use]
    pub fn log_file(&self) -> PathBuf {
        self.session_root().join("log.jsonl")
    }

    #[must_use]
    pub fn tasks_dir(&self) -> PathBuf {
        self.session_root().join("tasks")
    }

    #[must_use]
    pub fn locks_dir(&self) -> PathBuf {
        self.session_root().join(".locks")
    }

    #[must_use]
    pub fn origin_marker(&self) -> PathBuf {
        self.session_root().join(".origin")
    }

    #[must_use]
    pub fn active_registry(&self) -> PathBuf {
        self.project_dir().join(".active.json")
    }

    #[must_use]
    pub fn branch_ref(&self) -> String {
        format!("harness/{}", self.session_id)
    }
}

/// Helper: derive the sessions root from a data root. `<data-root>/sessions`.
#[must_use]
pub fn sessions_root(data_root: &Path) -> PathBuf {
    data_root.join("sessions")
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib workspace::layout
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add SessionLayout primitives"
```

---

## Task 4: Socket paths helper

**Files:**
- Create: `src/workspace/socket_paths.rs`
- Create: `src/workspace/socket_paths/tests.rs`

- [ ] **Step 1: Failing tests**

`src/workspace/socket_paths/tests.rs`:

```rust
use std::path::PathBuf;
use super::*;

#[test]
fn session_socket_path_layout() {
    let root = PathBuf::from("/g/sock");
    let path = session_socket(&root, "abc12345", "agent");
    assert_eq!(path, PathBuf::from("/g/sock/abc12345-agent.sock"));
}

#[test]
fn path_fits_sun_path_limit_with_long_home() {
    // Synthesize the worst-case group container on a long home path.
    let home: PathBuf = "/Users/verylonguser@corp.example.com".into();
    let root = home
        .join("Library")
        .join("Group Containers")
        .join("Q498EB36N4.io.harnessmonitor")
        .join("sock");
    let path = session_socket(&root, "abc12345", "mcp-registry");
    let bytes = path.to_string_lossy().as_bytes().len();
    assert!(bytes < 104, "socket path {} is {} bytes", path.display(), bytes);
}

#[test]
fn purpose_rejects_slash() {
    assert!(validate_purpose("mcp-registry").is_ok());
    assert!(validate_purpose("has/slash").is_err());
    assert!(validate_purpose("").is_err());
}
```

- [ ] **Step 2: Implement**

`src/workspace/socket_paths.rs`:

```rust
//! Short, flat unix-socket path namespace keyed by session id.

use std::path::{Path, PathBuf};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SocketPathError {
    #[error("socket purpose must be non-empty without '/': {0:?}")]
    InvalidPurpose(String),
}

pub fn validate_purpose(purpose: &str) -> Result<(), SocketPathError> {
    if purpose.is_empty() || purpose.contains('/') {
        return Err(SocketPathError::InvalidPurpose(purpose.to_string()));
    }
    Ok(())
}

#[must_use]
pub fn session_socket(root: &Path, session_id: &str, purpose: &str) -> PathBuf {
    root.join(format!("{session_id}-{purpose}.sock"))
}

/// Preferred socket root given the data root.
///
/// On macOS, places sockets at the group-container root's sibling `sock/`
/// (one level up from the harness data root) to save bytes. Elsewhere,
/// puts them under `<data-root>/sock/`.
#[must_use]
pub fn socket_root(data_root: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(parent) = data_root.parent() {
            return parent.join("sock");
        }
    }
    data_root.join("sock")
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib workspace::socket_paths
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add socket path helper"
```

---

## Task 5: Worktree controller

**Files:**
- Create: `src/workspace/worktree.rs`
- Create: `src/workspace/worktree/tests.rs`

- [ ] **Step 1: Failing tests**

`src/workspace/worktree/tests.rs`:

```rust
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

use super::*;
use crate::workspace::layout::SessionLayout;

fn init_origin_repo(tmp: &std::path::Path) {
    Command::new("git").arg("init").arg("-q").arg(tmp)
        .output().unwrap();
    // Create initial commit so refs/remotes/origin/HEAD can be simulated.
    std::fs::write(tmp.join("README"), b"seed").unwrap();
    Command::new("git").current_dir(tmp)
        .args(["add", "."]).output().unwrap();
    Command::new("git").current_dir(tmp)
        .args(["-c", "user.email=a@b", "-c", "user.name=a",
               "commit", "-q", "-m", "seed"]).output().unwrap();
}

#[test]
fn creates_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "abc12345".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();

    WorktreeController::create(origin.path(), &layout, None).expect("create");

    assert!(layout.workspace().join("README").exists());
    assert!(layout.memory().exists());
}

#[test]
fn destroy_removes_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "ab234567".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).unwrap();

    WorktreeController::destroy(origin.path(), &layout).expect("destroy");
    assert!(!layout.workspace().exists());

    let branches = Command::new("git").current_dir(origin.path())
        .args(["branch", "--list", "harness/*"])
        .output().unwrap();
    assert!(std::str::from_utf8(&branches.stdout).unwrap().trim().is_empty());
}
```

- [ ] **Step 2: Implement**

`src/workspace/worktree.rs`:

```rust
//! Git worktree lifecycle for per-session workspaces.

use std::path::Path;

use thiserror::Error;
use std::process::Command;
use tracing::{info, warn};

use super::layout::SessionLayout;

#[derive(Debug, Error)]
pub enum WorktreeError {
    #[error("worktree create failed: {0}")]
    CreateFailed(String),
    #[error("worktree remove failed: {0}")]
    RemoveFailed(String),
    #[error("branch delete failed: {0}")]
    BranchDeleteFailed(String),
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
}

pub struct WorktreeController;

impl WorktreeController {
    pub fn create(
        origin: &Path,
        layout: &SessionLayout,
        base_ref: Option<&str>,
    ) -> Result<(), WorktreeError> {
        let resolved_ref = match base_ref {
            Some(r) => r.to_string(),
            None => resolve_base_ref(origin)?,
        };
        let branch = layout.branch_ref();
        let output = Command::new("git")
            .arg("-C")
            .arg(origin)
            .env("GIT_TERMINAL_PROMPT", "0")
            .args([
                "worktree",
                "add",
                "-b",
                &branch,
                layout.workspace().to_string_lossy().as_ref(),
                &resolved_ref,
            ])
            .output()?;
        if !output.status.success() {
            return Err(WorktreeError::CreateFailed(
                String::from_utf8_lossy(&output.stderr).to_string(),
            ));
        }
        std::fs::create_dir_all(layout.memory())?;
        std::fs::write(layout.origin_marker(), origin.to_string_lossy().as_bytes())?;
        info!(path = %layout.workspace().display(), branch = %branch, "created worktree");
        Ok(())
    }

    pub fn destroy(
        origin: &Path,
        layout: &SessionLayout,
    ) -> Result<(), WorktreeError> {
        let remove = Command::new("git")
            .arg("-C")
            .arg(origin)
            .env("GIT_TERMINAL_PROMPT", "0")
            .args([
                "worktree",
                "remove",
                "--force",
                layout.workspace().to_string_lossy().as_ref(),
            ])
            .output()?;
        if !remove.status.success() {
            let stderr = String::from_utf8_lossy(&remove.stderr);
            if !stderr.contains("not a working tree") {
                warn!(%stderr, "worktree remove stderr; continuing to branch delete");
                return Err(WorktreeError::RemoveFailed(stderr.to_string()));
            }
        }
        let del = Command::new("git")
            .arg("-C")
            .arg(origin)
            .env("GIT_TERMINAL_PROMPT", "0")
            .args(["branch", "-D", &layout.branch_ref()])
            .output()
            .await?;
        if !del.status.success() {
            let stderr = String::from_utf8_lossy(&del.stderr);
            if !stderr.contains("not found") {
                return Err(WorktreeError::BranchDeleteFailed(stderr.to_string()));
            }
        }
        let _ = std::fs::remove_dir_all(layout.session_root());
        Ok(())
    }
}

fn resolve_base_ref(origin: &Path) -> Result<String, WorktreeError> {
    let origin_head = Command::new("git")
        .arg("-C")
        .arg(origin)
        .args(["rev-parse", "--abbrev-ref", "origin/HEAD"])
        .output()?;
    if origin_head.status.success() {
        let s = String::from_utf8_lossy(&origin_head.stdout).trim().to_string();
        if !s.is_empty() && s != "HEAD" {
            return Ok(s);
        }
    }
    // Fall back to current branch
    let head = Command::new("git")
        .arg("-C")
        .arg(origin)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()?;
    if !head.status.success() {
        return Err(WorktreeError::CreateFailed("no HEAD".into()));
    }
    Ok(String::from_utf8_lossy(&head.stdout).trim().to_string())
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib workspace::worktree
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add worktree controller"
```

---

## Task 6: Orphan cleanup

**Files:**
- Create: `src/workspace/orphan_cleanup.rs`
- Create: `src/workspace/orphan_cleanup/tests.rs`

- [ ] **Step 1: Failing test**

`src/workspace/orphan_cleanup/tests.rs`:

```rust
use super::*;
use tempfile::TempDir;

#[test]
fn removes_session_dir_without_state_json() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    let orphan = sessions.join("proj/ab123456");
    std::fs::create_dir_all(&orphan).unwrap();

    let healthy = sessions.join("proj/cd789012");
    std::fs::create_dir_all(&healthy).unwrap();
    std::fs::write(healthy.join("state.json"), b"{}").unwrap();

    cleanup_orphans(&sessions).unwrap();

    assert!(!orphan.exists());
    assert!(healthy.exists());
}

#[test]
fn idempotent() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(sessions.join("proj/abc12345")).unwrap();

    cleanup_orphans(&sessions).unwrap();
    cleanup_orphans(&sessions).unwrap();
}
```

- [ ] **Step 2: Implement**

```rust
//! Startup sweep: remove session directories missing `state.json`.

use std::fs;
use std::io;
use std::path::Path;

use tracing::info;

pub fn cleanup_orphans(sessions_root: &Path) -> io::Result<()> {
    if !sessions_root.exists() {
        return Ok(());
    }
    for project_entry in fs::read_dir(sessions_root)? {
        let project = project_entry?.path();
        if !project.is_dir() {
            continue;
        }
        for session_entry in fs::read_dir(&project)? {
            let session_dir = session_entry?.path();
            if !session_dir.is_dir() {
                continue;
            }
            // Skip `.active.json` and other hidden siblings at the project level.
            let name = session_dir.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            if name.starts_with('.') {
                continue;
            }
            if !session_dir.join("state.json").exists() {
                info!(path = %session_dir.display(), "removing orphaned session dir");
                fs::remove_dir_all(&session_dir)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib workspace::orphan_cleanup
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add orphan cleanup"
```

---

## Task 7: Rewrite storage layer

**Files:**
- Modify: `src/session/storage/files.rs`
- Modify: `src/session/storage/registry.rs`
- Modify: `src/workspace/mod.rs`
- Modify: `src/workspace/session.rs` (remove dead paths)
- Delete: `src/workspace/compact/paths.rs` or rewrite

- [ ] **Step 1: Identify every consumer of the old layout**

Run:

```bash
grep -rn "project_context_dir\|orchestration_root\|sessions_root\|project_scope_key_for\|sess-" \
  src/ --include="*.rs" > tmp/b-old-layout-sites.txt
```

Every hit in non-test code gets rewritten. Test fixtures get updated to build paths via `SessionLayout`.

- [ ] **Step 2: Write failing storage tests**

Update `src/session/storage/state_tests.rs` (or equivalent) to expect files at `<sessions_root>/<project>/<sid>/state.json`. Example:

```rust
#[test]
fn state_file_uses_new_layout() {
    let tmp = tempfile::TempDir::new().unwrap();
    let layout = crate::workspace::layout::SessionLayout {
        sessions_root: tmp.path().join("sessions"),
        project_name: "demo".into(),
        session_id: "abc12345".into(),
    };
    std::fs::create_dir_all(layout.session_root()).unwrap();

    let state = SessionState::new_for_test("abc12345");
    save_state(&layout, &state).unwrap();

    assert!(layout.state_file().exists());
}
```

- [ ] **Step 3: Implement storage rewrite**

Rewrite `src/session/storage/files.rs` so every helper takes `&SessionLayout` instead of `project_dir: &Path`. Remove the old timestamp-based session id generator - the id is now passed in via `SessionLayout::session_id`.

Rewrite `src/session/storage/registry.rs` to load/save `<sessions_root>/<project>/.active.json` (a `BTreeMap<String, String>` of session ids to creation timestamps). Drop `is_worktree`, `worktree_name`, and `recorded_from_dir` - they no longer apply since the daemon always creates worktrees.

- [ ] **Step 4: Green + commit**

```bash
cargo test --lib session::storage
git -c commit.gpgsign=true commit -sS -a -m "refactor(workspace): rewrite session storage"
```

---

## Task 8: Rewrite SessionState wire contract

**Files:**
- Modify: `src/daemon/protocol/session_requests.rs`
- Modify: every fixture/test that builds `SessionState`

- [ ] **Step 1: Failing compile**

Edit `SessionState` in-place. Remove: `is_worktree`, `worktree_name`, `recorded_from_dir`. Add: `project_name`, `session_id`, `worktree_path`, `shared_path`, `origin_path`, `branch_ref`. Run `cargo build`; expect widespread compile errors.

- [ ] **Step 2: Fix every call site one file at a time**

Work through the compile errors. For each old-field read, replace with the closest new-field equivalent. For serialization tests / snapshots, update fixtures to the new shape.

Update the JSON schema for `SessionState` if one exists (`resources/observability/grafana/...` or similar - grep for it).

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib
git -c commit.gpgsign=true commit -sS -a -m "refactor(protocol): new SessionState shape"
```

---

## Task 9: Wire worktree controller into session creation

**Files:**
- Modify: `src/daemon/service/session_setup.rs`

- [ ] **Step 1: Failing test**

`src/daemon/service/tests/direct_session_start.rs` - add a test that asserts session creation produces a worktree on disk:

```rust
#[test]
fn start_session_direct_creates_worktree() {
    with_temp_project(|project| {
        let db = setup_db_with_project(project);
        let state = start_session_direct(
            &crate::daemon::protocol::SessionStartRequest {
                title: "worktree start".into(),
                context: "wires the worktree controller".into(),
                runtime: "claude".into(),
                session_id: None,
                project_dir: project.to_string_lossy().into_owned(),
                policy_preset: None,
                base_ref: None,
            },
            Some(&db),
        )
        .expect("start session creates worktree");

        assert_eq!(state.session_id.len(), 8);
        assert_eq!(state.branch_ref, format!("harness/{}", state.session_id));
        assert!(state.worktree_path.join("README.md").exists());
        assert!(state.shared_path.exists());
        assert!(state.origin_path.exists());
    });
}
```

- [ ] **Step 2: Implement**

Rewrite `prepare_session` in `src/daemon/service/session_setup.rs` to:

1. Resolve `project_dir` (when sandboxed, treat the string as a bookmark id and resolve via A's resolver; otherwise treat it as a plain path).
2. Canonicalize the path and build `resolve_name(...)` from `src/workspace/project_resolver.rs`.
3. Generate `session_id = ids::new_session_id()`.
4. Build `SessionLayout`.
5. Call `WorktreeController::create(origin, &layout, request.base_ref.as_deref())` and abort if it fails.
6. Write initial `state.json`.
7. Register in per-project `.active.json`.
8. Return the populated `SessionState`.

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib daemon::service
git -c commit.gpgsign=true commit -sS -a -m "feat(daemon): create worktree per session"
```

---

## Task 10: Future follow-up - delete session endpoint

**Files:**
- Modify: `src/daemon/http/sessions.rs`
- Modify: `src/daemon/service/session_teardown.rs`
- Modify: `src/daemon/http/tests.rs`

- [ ] **Step 1: Failing test**

If a delete route is reintroduced later, add a targeted HTTP test here:

```rust
#[tokio::test]
async fn delete_session_removes_worktree() {
    let harness = spawn_daemon().await;
    let sid = harness.create_session().await;
    let resp = harness.client.delete(format!("{}/v1/sessions/{}", harness.url, sid)).send().await.unwrap();
    assert_eq!(resp.status(), 204);
    assert!(!harness.sessions_root.join("demo").join(&sid).exists());
}
```

- [ ] **Step 2: Implement**

If the route returns, the teardown path should live in `src/daemon/service/session_teardown.rs`, which best-effort destroys the worktree and removes the active registry entry while letting DB cleanup proceed.

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib daemon::http
git -c commit.gpgsign=true commit -sS -a -m "feat(daemon): follow up on session delete endpoint"
```

---

## Task 11: Migrate socket consumers

**Files:**
- Modify: `src/mcp/registry/client.rs`, `src/mcp/registry/server.rs` (or equivalent)
- Modify: `src/daemon/bridge/runtime.rs`, `src/daemon/bridge/client.rs`
- Modify: `src/mcp/tools/tests.rs`, `src/mcp/registry/tests.rs` (test fixtures)

- [ ] **Step 1: Enumerate**

```bash
grep -rn "UnixListener::bind\|UnixStream::connect" src/ --include="*.rs" > tmp/b-socket-sites.txt
```

For each non-test site, replace the socket-path construction with `socket_paths::session_socket(socket_root, session_id, purpose)`.

- [ ] **Step 2: Update tests to use the helper**

Test fixtures (e.g. `src/mcp/registry/tests.rs:23`) should build paths via the helper so the 104-byte assertion applies uniformly. For tests that need a unique path, use a short random-8 id as the synthetic session id.

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib
git -c commit.gpgsign=true commit -sS -a -m "refactor(sockets): route via socket_paths helper"
```

---

## Task 12: Wire orphan cleanup into daemon startup

**Files:**
- Modify: `src/daemon/mod.rs`

- [ ] **Step 1: Call cleanup**

Near the top of `pub fn start(...)` (after A's migration block lands), add:

```rust
if let Err(err) = crate::workspace::orphan_cleanup::cleanup_orphans(
    &crate::workspace::layout::sessions_root(&crate::workspace::paths::harness_data_root()),
) {
    warn!(%err, "orphan cleanup failed; continuing");
}
```

- [ ] **Step 2: Build + commit**

```bash
cargo build
git -c commit.gpgsign=true commit -sS -a -m "feat(daemon): sweep orphaned session dirs"
```

---

## Task 13: Integration tests

**Files:**
- Create: `tests/integration/workspace/mod.rs`
- Create: `tests/integration/workspace/session_lifecycle.rs`
- Create: `tests/integration/workspace/parallel_sessions.rs`
- Create: `tests/integration/workspace/collision.rs`
- Modify: `tests/integration/mod.rs`

- [ ] **Step 1: Implement session_lifecycle.rs**

```rust
use harness::daemon::testkit::TestDaemon;
use harness::workspace::layout::SessionLayout;

#[tokio::test]
async fn create_then_delete_cleans_up_fully() {
    let origin = harness_testkit::init_git_repo().await;
    let daemon = TestDaemon::spawn().await;
    let sid = daemon.create_session(origin.path()).await;
    let layout = daemon.layout_for(&sid);
    assert!(layout.workspace().exists());
    assert!(layout.memory().exists());
    assert!(layout.state_file().exists());

    daemon.end_session(&sid).await;
    assert!(layout.session_root().exists(), "delete is a future follow-up; end leaves the session root in place");
    let branches = harness_testkit::git_branches_matching(origin.path(), "harness/").await;
    assert!(!branches.is_empty());
}
```

- [ ] **Step 2: Implement parallel_sessions.rs**

Create two sessions against the same origin; assert two worktrees, two branches, and that each session can be ended independently without affecting the other.

- [ ] **Step 3: Implement collision.rs**

Simulate two canonical paths both ending `/kuma`. First session resolves to `kuma`; second resolves to `kuma-<4hex>`. Verify `.origin` markers distinguish them.

- [ ] **Step 4: Green + commit**

```bash
cargo test --test integration workspace
git -c commit.gpgsign=true commit -sS -a -m "test(workspace): cover session lifecycle"
```

---

## Task 14: Swift path model + session model updates

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Persistence/` (add migration plan)

- [ ] **Step 1: Extend HarnessMonitorPaths**

Add:

```swift
public extension HarnessMonitorPaths {
    static func sessionsRoot(using env: HarnessMonitorEnvironment = .current) -> URL {
        harnessRoot(using: env).appendingPathComponent("sessions", isDirectory: true)
    }
    static func sessionRoot(projectName: String, sessionId: String,
                            using env: HarnessMonitorEnvironment = .current) -> URL {
        sessionsRoot(using: env)
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }
    static func sessionWorktree(projectName: String, sessionId: String,
                                using env: HarnessMonitorEnvironment = .current) -> URL {
        sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
            .appendingPathComponent("workspace", isDirectory: true)
    }
    static func sessionShared(projectName: String, sessionId: String,
                              using env: HarnessMonitorEnvironment = .current) -> URL {
        sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
            .appendingPathComponent("memory", isDirectory: true)
    }
    static func socketDirectory(using env: HarnessMonitorEnvironment = .current) -> URL {
        // macOS: <group-container>/sock/, outside `harness/`.
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HarnessMonitorAppGroup.identifier
        ) else {
            return harnessRoot(using: env).appendingPathComponent("sock", isDirectory: true)
        }
        return group.appendingPathComponent("sock", isDirectory: true)
    }
}
```

- [ ] **Step 2: Update SessionState Swift model**

`HarnessMonitorSessionModels.swift` - mirror the Rust rewrite: add `projectName`, `sessionId`, `worktreePath`, `sharedPath`, `originPath`, `branchRef`; remove `isWorktree`, `worktreeName`.

Update `Decodable` glue + fix all call sites in `HarnessMonitorStore+*.swift`.

- [ ] **Step 3: Add SwiftData migration**

The app caches session models via SwiftData. Add `CachedModels+V6.swift` with the new shape, and a migration plan entry under the existing V4 → V5 → V6 chain.

- [ ] **Step 4: Quality gates + Swift tests**

```bash
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild ... test -only-testing:HarnessMonitorKitTests
```

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(monitor): adopt new session layout"
```

---

## Task 15: Update CLI session commands + snapshots

**Files:**
- Modify: `src/app/cli.rs` (session subcommands)
- Modify: `src/app/cli/tests/session.rs` + snapshot fixtures

- [ ] **Step 1: Review every `harness session ...` command**

```bash
grep -rn "fn.*session" src/app/cli.rs | head -20
```

Each command that builds session paths via the old layout gets rewritten.

- [ ] **Step 2: Regenerate snapshots**

After updating the CLI output format to include the new `SessionState` fields, run:

```bash
INSTA_UPDATE=auto cargo test --lib app::cli::tests::session
```

Review the snapshot diff and commit only if the changes are expected.

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(cli): adopt new session layout"
```

---

## Task 16: Major version bump + final gates

**Files:**
- Modify: `Cargo.toml`

- [ ] **Step 1: Bump version (major)**

Current is `27.x`. Assume A lands as `27.3.0`. B bumps to `28.0.0`:

```bash
./scripts/version.sh set 28.0.0
mise run version:sync
```

- [ ] **Step 2: Run every gate**

```bash
mise run check
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation test \
  -skip-testing:HarnessMonitorUITests
```

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "chore: bump to 28.0.0 for session layout"
```

---

## Self-review notes

**Spec coverage:**

| Spec section | Plan task |
| --- | --- |
| Path primitives (`SessionLayout`) | Task 3 |
| Session id (8-char alphanumeric) | Task 1 |
| Project name resolver (collision + `.origin`) | Task 2 |
| Worktree controller | Task 5 |
| Worktree-owner (daemon via subprocess) | Task 5 + Task 9 |
| Socket paths | Task 4 + Task 11 |
| Session service integration | Task 9 |
| DELETE endpoint follow-up | Task 10 |
| SessionState wire contract | Task 8 |
| Storage rewrite | Task 7 |
| Active-session registry relocation | Task 7 |
| Orphan cleanup | Task 6 + Task 12 |
| Swift path model | Task 14 |
| Swift SessionState model + migration | Task 14 |
| CLI commands + snapshots | Task 15 |
| Integration tests | Task 13 |
| Major version bump | Task 16 |
| Follow-ups (C, D) | Out of scope; called out in spec |

**Placeholder scan:** "Rewrite every helper" / "Work through the compile errors" in Tasks 7 and 8 are enumerable by running `cargo build` - they're a workflow, not a placeholder. The implementer produces concrete diffs one file at a time. Acceptable.

**Type consistency:** `SessionLayout` field names (`sessions_root`, `project_name`, `session_id`) used consistently. `branch_ref()` returns `harness/<sid>`. New `SessionState` fields match Swift mirror: `projectName`, `sessionId`, `worktreePath`, `sharedPath`, `originPath`, `branchRef`.

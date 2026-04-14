use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::session::storage;
use crate::workspace::{project_context_dir, resolve_git_checkout_identity};

use super::io::read_last_nonempty_line;
use super::sessions::list_session_ids_from_context_root;

#[derive(Debug, Clone)]
pub(super) struct InferredCheckout {
    pub(super) repository_root: PathBuf,
    pub(super) checkout_root: PathBuf,
    pub(super) is_worktree: bool,
    pub(super) worktree_name: Option<String>,
}

pub(super) fn repair_context_root(context_root: &Path) -> Result<Option<PathBuf>, CliError> {
    if !context_root.is_dir() {
        return Ok(None);
    }

    let has_sessions = context_has_sessions(context_root)?;
    let Some(identity) = infer_checkout_identity(context_root) else {
        if has_sessions {
            return Ok(Some(context_root.to_path_buf()));
        }
        prune_context_root(context_root, "pruned non-git project context")?;
        return Ok(None);
    };
    if !identity.checkout_root.exists() && !has_sessions {
        prune_context_root(context_root, "pruned missing checkout context")?;
        return Ok(None);
    }
    let canonical_context_root = project_context_dir(&identity.checkout_root);
    if canonical_context_root != context_root {
        reconcile_legacy_context(context_root, &canonical_context_root)?;
    }

    if canonical_context_root.is_dir() {
        storage::record_project_origin(&identity.checkout_root)?;
        return Ok(Some(canonical_context_root));
    }
    Ok(None)
}

pub(super) fn infer_checkout_identity(context_root: &Path) -> Option<InferredCheckout> {
    if let Some(origin) = storage::load_project_origin(context_root)
        && let Some(checkout_root) = origin_checkout_root(&origin)
    {
        if let Some(identity) = resolve_git_checkout_identity(&checkout_root) {
            let is_worktree = identity.is_worktree();
            let worktree_name = identity.worktree_name().map(ToString::to_string);
            return Some(InferredCheckout {
                repository_root: identity.repository_root,
                checkout_root: identity.checkout_root,
                is_worktree,
                worktree_name,
            });
        }
        let repository_root = origin
            .repository_root
            .as_deref()
            .map_or_else(|| checkout_root.clone(), PathBuf::from);
        return Some(InferredCheckout {
            repository_root,
            checkout_root,
            is_worktree: origin.is_worktree,
            worktree_name: origin.worktree_name,
        });
    }

    let cwd = infer_ledger_cwd(context_root)?;
    let identity = resolve_git_checkout_identity(&cwd)?;
    let is_worktree = identity.is_worktree();
    let worktree_name = identity.worktree_name().map(ToString::to_string);
    Some(InferredCheckout {
        repository_root: identity.repository_root,
        checkout_root: identity.checkout_root,
        is_worktree,
        worktree_name,
    })
}

pub(super) fn infer_ledger_cwd(context_root: &Path) -> Option<PathBuf> {
    let ledger_path = context_root
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    read_last_nonempty_line(&ledger_path, "agent ledger")
        .ok()
        .flatten()
        .and_then(|line| serde_json::from_str::<serde_json::Value>(&line).ok())
        .and_then(|entry| {
            entry
                .get("cwd")
                .and_then(serde_json::Value::as_str)
                .map(PathBuf::from)
        })
}

fn reconcile_legacy_context(
    context_root: &Path,
    canonical_context_root: &Path,
) -> Result<(), CliError> {
    if context_has_sessions(context_root)? {
        migrate_and_log_context(context_root, canonical_context_root)?;
    } else {
        prune_context_root(context_root, "pruned legacy project alias")?;
    }
    Ok(())
}

fn migrate_and_log_context(source: &Path, target: &Path) -> Result<(), CliError> {
    migrate_context_root(source, target)?;
    emit_info(&format!(
        "migrated legacy project context {} to {}",
        source.display(),
        target.display()
    ));
    Ok(())
}

fn origin_checkout_root(origin: &storage::ProjectOriginRecord) -> Option<PathBuf> {
    origin
        .checkout_root
        .as_deref()
        .or(Some(origin.recorded_from_dir.as_str()))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn context_has_sessions(context_root: &Path) -> Result<bool, CliError> {
    Ok(!list_session_ids_from_context_root(context_root)?.is_empty())
}

fn prune_context_root(context_root: &Path, reason: &str) -> Result<(), CliError> {
    if !context_root.exists() {
        return Ok(());
    }
    remove_context_dir(context_root)?;
    log_context_prune(context_root, reason);
    Ok(())
}

fn log_context_prune(context_root: &Path, reason: &str) {
    emit_info(&format!("{reason}: {}", context_root.display()));
}

/// Manual tracing event dispatch. The `info!` macro has inherent cognitive
/// complexity of 8 due to its internal expansion (tokio-rs/tracing#553),
/// which exceeds the pedantic threshold of 7.
fn emit_info(message: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "info",
        "harness::daemon::index",
        Level::INFO,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

fn remove_context_dir(context_root: &Path) -> Result<(), CliError> {
    fs::remove_dir_all(context_root).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "remove project context {}: {error}",
            context_root.display()
        ))
    })?;
    Ok(())
}

fn migrate_context_root(source: &Path, target: &Path) -> Result<(), CliError> {
    if source == target || !source.is_dir() {
        return Ok(());
    }
    if !target.exists() {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create canonical project context parent {}: {error}",
                    parent.display()
                ))
            })?;
        }
        fs::rename(source, target).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "move project context {} -> {}: {error}",
                source.display(),
                target.display()
            ))
        })?;
        return Ok(());
    }

    merge_context_roots(source, target)?;
    fs::remove_dir_all(source).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "remove migrated project context {}: {error}",
            source.display()
        ))
    })?;
    Ok(())
}

fn merge_context_roots(source: &Path, target: &Path) -> Result<(), CliError> {
    merge_active_registries(source, target)?;
    merge_append_only_file(
        &source.join("agents").join("ledger").join("events.jsonl"),
        &target.join("agents").join("ledger").join("events.jsonl"),
    )?;

    let mut pending = vec![source.to_path_buf()];
    while let Some(current) = pending.pop() {
        merge_directory_entries(source, target, &current, &mut pending)?;
    }

    Ok(())
}

fn merge_directory_entries(
    source: &Path,
    target: &Path,
    current: &Path,
    pending: &mut Vec<PathBuf>,
) -> Result<(), CliError> {
    for entry in fs::read_dir(current).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read project context merge directory {}: {error}",
            current.display()
        ))
    })? {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        let Ok(relative) = path.strip_prefix(source) else {
            continue;
        };
        if skip_merged_path(relative) {
            continue;
        }
        let target_path = target.join(relative);
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            fs::create_dir_all(&target_path).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create merged project directory {}: {error}",
                    target_path.display()
                ))
            })?;
            pending.push(path);
            continue;
        }
        if target_path.exists() {
            continue;
        }
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create merged project file parent {}: {error}",
                    parent.display()
                ))
            })?;
        }
        fs::copy(&path, &target_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "copy merged project file {} -> {}: {error}",
                path.display(),
                target_path.display()
            ))
        })?;
    }
    Ok(())
}

fn merge_active_registries(source: &Path, target: &Path) -> Result<(), CliError> {
    let source_path = source.join("orchestration").join("active.json");
    if !source_path.is_file() {
        return Ok(());
    }

    let target_path = target.join("orchestration").join("active.json");
    let source_registry =
        read_json_typed::<storage::ActiveRegistry>(&source_path).unwrap_or_default();
    let mut target_registry =
        read_json_typed::<storage::ActiveRegistry>(&target_path).unwrap_or_default();
    for (session_id, timestamp) in source_registry.sessions {
        target_registry
            .sessions
            .entry(session_id)
            .and_modify(|current| {
                if timestamp > *current {
                    current.clone_from(&timestamp);
                }
            })
            .or_insert(timestamp);
    }
    if let Some(parent) = target_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create active registry parent {}: {error}",
                parent.display()
            ))
        })?;
    }
    write_json_pretty(&target_path, &target_registry)
}

fn merge_append_only_file(source: &Path, target: &Path) -> Result<(), CliError> {
    if !source.is_file() {
        return Ok(());
    }
    let contents = fs::read_to_string(source).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read append-only file {}: {error}",
            source.display()
        ))
    })?;
    if contents.trim().is_empty() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create append-only file parent {}: {error}",
                parent.display()
            ))
        })?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(target)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "open append-only file {}: {error}",
                target.display()
            ))
        })?;
    file.write_all(contents.as_bytes()).map_err(|error| {
        CliErrorKind::workflow_io(format!("append file {}: {error}", target.display()))
    })?;
    if !contents.ends_with('\n') {
        writeln!(file).map_err(|error| {
            CliErrorKind::workflow_io(format!("terminate file {}: {error}", target.display()))
        })?;
    }
    Ok(())
}

fn skip_merged_path(relative: &Path) -> bool {
    if relative
        .components()
        .any(|component| component.as_os_str() == ".locks")
    {
        return true;
    }
    matches!(
        relative.to_string_lossy().as_ref(),
        "project-origin.json" | "orchestration/active.json" | "agents/ledger/events.jsonl"
    )
}

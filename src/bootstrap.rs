use std::collections::HashSet;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::blocks::BlockRegistry;
use crate::core_defs::dirs_home;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::context::NormalizedEvent;
use crate::io::write_text;

/// Shell wrapper script that delegates to the project-local harness binary.
pub const WRAPPER: &str = r#"#!/bin/sh
set -eu

if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
  candidate="${CLAUDE_PROJECT_DIR}/.claude/plugins/suite/harness"
  if [ -x "${candidate}" ]; then
    exec "${candidate}" "$@"
  fi
  candidate="${CLAUDE_PROJECT_DIR}/.claude/skills/harness"
  if [ -x "${candidate}" ]; then
    exec "${candidate}" "$@"
  fi
fi

if command -v git >/dev/null 2>&1; then
  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    candidate="${repo_root}/.claude/plugins/suite/harness"
    if [ -x "${candidate}" ]; then
      exec "${candidate}" "$@"
    fi
    candidate="${repo_root}/.claude/skills/harness"
    if [ -x "${candidate}" ]; then
      exec "${candidate}" "$@"
    fi
  fi
fi

echo "harness: unable to resolve .claude/plugins/suite/harness" >&2
echo "or .claude/skills/harness from CLAUDE_PROJECT_DIR or git repo" >&2
exit 1
"#;

/// Choose the install directory for the harness wrapper.
///
/// Prefers `~/.local/bin` or `~/bin` if they are on PATH and writable.
/// Falls back to any writable user PATH directory, then `~/.local/bin`
/// unconditionally.
///
/// Returns `(target_dir, already_on_path)`.
///
/// # Errors
/// Returns `CliError` if no suitable directory is found.
pub fn choose_install_dir(path_env: &str) -> Result<(PathBuf, bool), CliError> {
    choose_install_dir_with_home(path_env, &dirs_home())
}

/// Like [`choose_install_dir`] but accepts an explicit `home` directory so
/// callers (and tests) don't depend on the ambient `HOME` env var.
///
/// # Errors
/// Returns `CliError` if no suitable directory is found.
pub fn choose_install_dir_with_home(
    path_env: &str,
    home: &Path,
) -> Result<(PathBuf, bool), CliError> {
    let home = canonical_or_same(home);
    let path_dirs = path_candidates(path_env);
    let preferred = [home.join(".local").join("bin"), home.join("bin")];

    for pref in &preferred {
        let canonical_pref = canonical_or_same(pref);
        if path_dirs
            .iter()
            .any(|p| canonical_or_same(p) == canonical_pref)
            && is_installable(pref)
        {
            return Ok((pref.clone(), true));
        }
    }

    for path_dir in &path_dirs {
        let canonical_dir = canonical_or_same(path_dir);
        if canonical_dir.starts_with(&home) && is_installable(path_dir) {
            return Ok((path_dir.clone(), true));
        }
    }

    let fallback = &preferred[0];
    if is_installable(fallback) {
        let canonical_fallback = canonical_or_same(fallback);
        let on_path = path_dirs
            .iter()
            .any(|p| canonical_or_same(p) == canonical_fallback);
        return Ok((fallback.clone(), on_path));
    }

    Err(CliErrorKind::missing_file("no writable user PATH directory found").into())
}

/// Install the harness wrapper script into the target directory.
///
/// Creates the directory if needed, writes the wrapper, and sets it
/// executable. If the wrapper already has the right content, only
/// ensures the executable bit.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn install_wrapper(target_dir: &Path) -> Result<PathBuf, CliError> {
    fs::create_dir_all(target_dir)?;

    let target = target_dir.join("harness");

    if target.exists() {
        // Never overwrite an existing executable. The file could be:
        // - The compiled Rust binary
        // - A user-installed shim
        // - A previous version of the wrapper
        // In all cases, leave it alone.
        let meta = fs::metadata(&target)?;
        let mut perms = meta.permissions();
        perms.set_mode(perms.mode() | 0o111);
        fs::set_permissions(&target, perms)?;
        return Ok(target);
    }

    write_text(&target, WRAPPER)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o755))?;
    Ok(target)
}

/// Bootstrap main entry point.
///
/// Verifies the project source wrapper exists, chooses an install dir,
/// and installs the wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn main(project_dir: &Path, path_env: &str) -> Result<i32, CliError> {
    main_with_home(project_dir, path_env, &dirs_home())
}

/// Like [`main`] but accepts an explicit `home` directory for testability.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn main_with_home(project_dir: &Path, path_env: &str, home: &Path) -> Result<i32, CliError> {
    let plugin_dir = project_dir.join(".claude").join("plugins").join("suite");
    let plugin_path = plugin_dir.join("harness");
    let legacy_path = project_dir.join(".claude").join("skills").join("harness");

    if !plugin_path.exists() && !legacy_path.exists() {
        return Err(CliErrorKind::missing_file(cow!(
            "missing source wrapper: {} or {}",
            plugin_path.display(),
            legacy_path.display()
        ))
        .into());
    }

    let (target_dir, _already_on_path) = choose_install_dir_with_home(path_env, home)?;
    install_wrapper(&target_dir)?;

    // Sync plugin source files to Claude Code's plugin cache so agent
    // definitions, hooks, and skills stay up to date between sessions.
    if plugin_dir.is_dir() {
        sync_plugin_cache(&plugin_dir, home);
    }

    Ok(0)
}

/// Generate agent-specific bootstrap files in the project directory.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<Vec<PathBuf>, CliError> {
    match agent {
        HookAgent::ClaudeCode | HookAgent::GeminiCli | HookAgent::Codex => {
            write_process_agent_bootstrap(project_dir, agent)
        }
        HookAgent::OpenCode => write_opencode_bootstrap(project_dir),
    }
}

/// Returns whether `harness` resolves from the provided PATH.
#[must_use]
pub fn harness_on_path(path_env: &str) -> bool {
    path_candidates(path_env)
        .iter()
        .any(|dir| dir.join("harness").is_file())
}

fn write_process_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<Vec<PathBuf>, CliError> {
    let path = match agent {
        HookAgent::ClaudeCode => project_dir.join(".claude").join("settings.json"),
        HookAgent::GeminiCli => project_dir.join(".gemini").join("settings.json"),
        HookAgent::Codex => project_dir.join(".codex").join("hooks.json"),
        HookAgent::OpenCode => unreachable!("handled separately"),
    };
    let registrations = process_agent_registrations(agent);
    let config = adapter_for(agent).generate_config(&registrations);
    write_text(&path, &config)?;

    let mut written = vec![path];
    if agent == HookAgent::Codex {
        let config_path = project_dir.join(".codex").join("config.toml");
        write_text(&config_path, &build_codex_config())?;
        written.push(config_path);
    }

    Ok(written)
}

fn write_opencode_bootstrap(project_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let plugin_path = project_dir
        .join(".opencode")
        .join("plugins")
        .join("harness-bridge.ts");
    let package_path = project_dir.join(".opencode").join("package.json");
    let registry = BlockRegistry::production();

    write_text(&plugin_path, &build_opencode_bridge(&registry)?)?;
    if !package_path.exists() {
        write_text(
            &package_path,
            "{\n  \"name\": \"harness-opencode\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n",
        )?;
    }

    Ok(vec![plugin_path, package_path])
}

fn process_agent_registrations(agent: HookAgent) -> Vec<HookRegistration> {
    let mut registrations = vec![command_registration(
        "session-start",
        lifecycle_command(agent, "session-start"),
        NormalizedEvent::SessionStart,
        None,
    )];

    if matches!(agent, HookAgent::ClaudeCode | HookAgent::GeminiCli) {
        registrations.push(command_registration(
            "pre-compact",
            lifecycle_command(agent, "pre-compact"),
            NormalizedEvent::BeforeCompaction,
            None,
        ));
        registrations.push(command_registration(
            "session-stop",
            lifecycle_command(agent, "session-stop"),
            NormalizedEvent::SessionEnd,
            None,
        ));
    }

    match agent {
        HookAgent::ClaudeCode => registrations.extend(claude_code_hooks(agent)),
        HookAgent::GeminiCli => registrations.extend(gemini_cli_hooks(agent)),
        HookAgent::Codex => registrations.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        )),
        HookAgent::OpenCode => unreachable!("handled separately"),
    }

    registrations
}

fn claude_code_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "guard-bash",
            NormalizedEvent::BeforeToolUse,
            Some("Bash"),
        ),
        hook_registration(
            agent,
            "guard-write",
            NormalizedEvent::BeforeToolUse,
            Some("Write|Edit"),
        ),
        hook_registration(
            agent,
            "guard-question",
            NormalizedEvent::BeforeToolUse,
            Some("AskUserQuestion"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "verify-bash",
            NormalizedEvent::AfterToolUse,
            Some("Bash"),
        ),
        hook_registration(
            agent,
            "verify-write",
            NormalizedEvent::AfterToolUse,
            Some("Write|Edit"),
        ),
        hook_registration(
            agent,
            "verify-question",
            NormalizedEvent::AfterToolUse,
            Some("AskUserQuestion"),
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, Some(".*")),
        hook_registration(
            agent,
            "enrich-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ),
        hook_registration(agent, "context-agent", NormalizedEvent::SubagentStart, None),
        hook_registration(agent, "validate-agent", NormalizedEvent::SubagentStop, None),
    ]
}

fn gemini_cli_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "guard-bash",
            NormalizedEvent::BeforeToolUse,
            Some("run_shell_command"),
        ),
        hook_registration(
            agent,
            "guard-write",
            NormalizedEvent::BeforeToolUse,
            Some("write_file|replace"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "verify-bash",
            NormalizedEvent::AfterToolUse,
            Some("run_shell_command"),
        ),
        hook_registration(
            agent,
            "verify-write",
            NormalizedEvent::AfterToolUse,
            Some("write_file|replace"),
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, Some(".*")),
        hook_registration(
            agent,
            "enrich-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ),
    ]
}

fn build_codex_config() -> String {
    concat!(
        "notify = [\"harness\", \"hook\", \"--agent\", \"codex\", \"suite:run\", \"audit-turn\"]\n",
        "\n",
        "[features]\n",
        "codex_hooks = true\n"
    )
    .to_string()
}

fn lifecycle_command(agent: HookAgent, subcommand: &str) -> String {
    match agent {
        HookAgent::ClaudeCode => {
            format!("harness {subcommand} --project-dir \"$CLAUDE_PROJECT_DIR\"")
        }
        HookAgent::GeminiCli => format!(
            "harness {subcommand} --project-dir \"${{CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}}\""
        ),
        HookAgent::Codex => format!("harness {subcommand} --project-dir \"$PWD\""),
        HookAgent::OpenCode => unreachable!("opencode lifecycle is handled by the bridge"),
    }
}

fn hook_registration(
    agent: HookAgent,
    name: &'static str,
    event: NormalizedEvent,
    matcher: Option<&str>,
) -> HookRegistration {
    HookRegistration {
        name,
        event,
        matcher: matcher.map(ToString::to_string),
        command: format!(
            "harness hook --agent {} suite:run {name}",
            adapter_for(agent).name()
        ),
    }
}

fn command_registration(
    name: &'static str,
    command: impl Into<String>,
    event: NormalizedEvent,
    matcher: Option<&str>,
) -> HookRegistration {
    HookRegistration {
        name,
        event,
        matcher: matcher.map(ToString::to_string),
        command: command.into(),
    }
}

fn build_opencode_bridge(registry: &BlockRegistry) -> Result<String, CliError> {
    let denied_binaries = registry
        .all_denied_binaries()
        .into_iter()
        .collect::<Vec<_>>();
    let denied_binaries_json = serde_json::to_string(&denied_binaries)
        .map_err(|error| CliErrorKind::serialize(cow!("opencode denied binaries: {error}")))?;
    let tool_guards = serde_json::to_string(&serde_json::json!({
        "bash": "guard-bash",
        "write": "guard-write",
        "edit": "guard-write",
    }))
    .map_err(|error| CliErrorKind::serialize(cow!("opencode tool guards: {error}")))?;
    let tool_verifiers = serde_json::to_string(&serde_json::json!({
        "bash": "verify-bash",
        "write": "verify-write",
        "edit": "verify-write",
    }))
    .map_err(|error| CliErrorKind::serialize(cow!("opencode tool verifiers: {error}")))?;

    let bridge = include_str!("../resources/opencode/harness-bridge.ts")
        .replace("__DENIED_BINARY_HINTS__", &denied_binaries_json)
        .replace("__TOOL_GUARDS__", &tool_guards)
        .replace("__TOOL_VERIFIERS__", &tool_verifiers);

    Ok(bridge)
}

/// Read the plugin version from `.claude-plugin/plugin.json`.
///
/// Returns `None` if the file is missing or unparseable.
fn read_plugin_version(plugin_dir: &Path) -> Option<String> {
    let json_path = plugin_dir.join(".claude-plugin").join("plugin.json");
    let text = fs::read_to_string(json_path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value.get("version")?.as_str().map(String::from)
}

/// Sync plugin source directories to the Claude Code plugin cache.
///
/// Copies `agents/`, `hooks/`, and `skills/` from the project source
/// into `~/.claude/plugins/cache/harness/suite/{version}/`, creating
/// or overwriting files as needed. Skips the binary (`harness`) since
/// it is already current. Degrades silently on any IO error.
fn sync_plugin_cache(plugin_dir: &Path, home: &Path) {
    let Some(version) = read_plugin_version(plugin_dir) else {
        return;
    };

    let cache_dir = home
        .join(".claude")
        .join("plugins")
        .join("cache")
        .join("harness")
        .join("suite")
        .join(&version);

    if !cache_dir.is_dir() {
        return;
    }

    for subdir in &["agents", "hooks", "skills"] {
        let source = plugin_dir.join(subdir);
        if source.is_dir() {
            let target = cache_dir.join(subdir);
            let _ = sync_directory(&source, &target);
        }
    }
}

/// Recursively copy all files from `source` into `target`, overwriting
/// any file whose content differs. Creates subdirectories as needed.
fn sync_directory(source: &Path, target: &Path) -> io::Result<()> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let dest = target.join(entry.file_name());
        if file_type.is_dir() {
            sync_directory(&entry.path(), &dest)?;
        } else if file_type.is_file() {
            let source_content = fs::read(entry.path())?;
            let needs_write = if let Ok(existing) = fs::read(&dest) {
                existing != source_content
            } else {
                true
            };
            if needs_write {
                fs::copy(entry.path(), &dest)?;
            }
        }
    }
    Ok(())
}

fn path_candidates(path_env: &str) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    for raw in path_env.split(':') {
        if raw.is_empty() {
            continue;
        }
        let path = expand_path(raw);
        if seen.insert(path.clone()) {
            candidates.push(path);
        }
    }
    candidates
}

fn expand_path(raw: &str) -> PathBuf {
    let path = PathBuf::from(raw);
    if raw.starts_with('~') {
        let home = dirs_home();
        let stripped = raw.strip_prefix("~/").unwrap_or("~");
        if stripped == "~" {
            return home;
        }
        return home.join(stripped);
    }
    fs::canonicalize(&path).unwrap_or(path)
}

fn is_installable(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;

    if path.exists() {
        if !path.is_dir() {
            return false;
        }
        // Check writable + executable
        if let Ok(meta) = path.metadata() {
            let mode = meta.mode();
            if meta.uid() == uzers::get_current_uid() {
                return mode & 0o300 == 0o300;
            }
            // Fallback: try to check group/other
            return mode & 0o011 != 0;
        }
        return false;
    }

    // Directory doesn't exist yet - check if parent is writable
    if let Some(parent) = path.parent() {
        return parent.exists() && is_installable(parent);
    }
    false
}

fn canonical_or_same(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use std::{thread, time::Duration};

    use super::*;

    #[test]
    fn wrapper_content_starts_with_shebang() {
        assert!(WRAPPER.starts_with("#!/bin/sh"));
    }

    #[test]
    fn wrapper_content_references_claude_project_dir() {
        assert!(WRAPPER.contains("CLAUDE_PROJECT_DIR"));
    }

    #[test]
    fn wrapper_content_references_plugin_path() {
        assert!(WRAPPER.contains(".claude/plugins/suite/harness"));
    }

    #[test]
    fn wrapper_content_references_legacy_path() {
        assert!(WRAPPER.contains(".claude/skills/harness"));
    }

    #[test]
    fn wrapper_content_references_git_rev_parse() {
        assert!(WRAPPER.contains("git rev-parse --show-toplevel"));
    }

    #[test]
    fn choose_install_dir_prefers_local_bin_on_path() {
        let dir = tempfile::tempdir().unwrap();
        let local_bin = dir.path().join(".local").join("bin");
        fs::create_dir_all(&local_bin).unwrap();

        let path_env = local_bin.to_string_lossy().into_owned();
        let (chosen, on_path) = choose_install_dir_with_home(&path_env, dir.path()).unwrap();
        // Canonicalize both to handle macOS /private/var vs /var symlink
        assert_eq!(
            chosen.canonicalize().unwrap_or(chosen),
            local_bin.canonicalize().unwrap_or(local_bin)
        );
        assert!(on_path);
    }

    #[test]
    fn install_wrapper_creates_executable_file() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");

        let path = install_wrapper(&target_dir).unwrap();

        assert!(path.exists());
        assert_eq!(fs::read_to_string(&path).unwrap(), WRAPPER);
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_ne!(mode & 0o111, 0, "should be executable");
    }

    #[test]
    fn install_wrapper_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");

        let first = install_wrapper(&target_dir).unwrap();
        let second = install_wrapper(&target_dir).unwrap();

        assert_eq!(first, second);
        assert_eq!(fs::read_to_string(&first).unwrap(), WRAPPER);
    }

    #[test]
    fn install_wrapper_preserves_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");
        fs::create_dir_all(&target_dir).unwrap();
        fs::write(target_dir.join("harness"), "existing content").unwrap();

        let path = install_wrapper(&target_dir).unwrap();
        // Must NOT overwrite - existing file is preserved
        assert_eq!(fs::read_to_string(path).unwrap(), "existing content");
    }

    #[test]
    fn main_fails_when_source_wrapper_missing() {
        let dir = tempfile::tempdir().unwrap();
        let err = main(dir.path(), "").unwrap_err();
        assert!(err.message().contains("missing source wrapper"));
    }

    #[test]
    fn main_succeeds_with_plugin_path() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir
            .path()
            .join(".claude")
            .join("plugins")
            .join("suite")
            .join("harness");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "#!/bin/sh\necho ok\n").unwrap();

        let bin_dir = dir.path().join(".local").join("bin");
        fs::create_dir_all(&bin_dir).unwrap();

        let path_env = bin_dir.to_string_lossy().into_owned();
        let result = main_with_home(dir.path(), &path_env, dir.path());

        assert_eq!(result.unwrap(), 0);
        assert!(bin_dir.join("harness").exists());
    }

    #[test]
    fn main_succeeds_with_legacy_path() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join(".claude").join("skills").join("harness");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "#!/bin/sh\necho ok\n").unwrap();

        let bin_dir = dir.path().join(".local").join("bin");
        fs::create_dir_all(&bin_dir).unwrap();

        let path_env = bin_dir.to_string_lossy().into_owned();
        let result = main_with_home(dir.path(), &path_env, dir.path());

        assert_eq!(result.unwrap(), 0);
        assert!(bin_dir.join("harness").exists());
    }

    #[test]
    fn path_candidates_deduplicates() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        let path_str = format!("{}:{}", bin.display(), bin.display());
        let candidates = path_candidates(&path_str);
        assert_eq!(candidates.len(), 1);
    }

    #[test]
    fn path_candidates_skips_empty_entries() {
        let candidates = path_candidates(":/usr/bin:");
        // Only /usr/bin should appear
        assert!(!candidates.is_empty());
        assert!(candidates.iter().all(|p| !p.as_os_str().is_empty()));
    }

    #[test]
    fn read_plugin_version_parses_json() {
        let dir = tempfile::tempdir().unwrap();
        let plugin_json_dir = dir.path().join(".claude-plugin");
        fs::create_dir_all(&plugin_json_dir).unwrap();
        fs::write(
            plugin_json_dir.join("plugin.json"),
            r#"{"name":"suite","version":"1.0.0"}"#,
        )
        .unwrap();

        assert_eq!(read_plugin_version(dir.path()), Some("1.0.0".to_string()));
    }

    #[test]
    fn read_plugin_version_returns_none_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_plugin_version(dir.path()), None);
    }

    #[test]
    fn sync_directory_copies_files() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        let target = dir.path().join("target");

        fs::create_dir_all(&source).unwrap();
        fs::write(source.join("a.md"), "content a").unwrap();
        fs::write(source.join("b.md"), "content b").unwrap();

        sync_directory(&source, &target).unwrap();

        assert_eq!(
            fs::read_to_string(target.join("a.md")).unwrap(),
            "content a"
        );
        assert_eq!(
            fs::read_to_string(target.join("b.md")).unwrap(),
            "content b"
        );
    }

    #[test]
    fn sync_directory_overwrites_stale_files() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        let target = dir.path().join("target");

        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(source.join("a.md"), "new content").unwrap();
        fs::write(target.join("a.md"), "old content").unwrap();

        sync_directory(&source, &target).unwrap();

        assert_eq!(
            fs::read_to_string(target.join("a.md")).unwrap(),
            "new content"
        );
    }

    #[test]
    fn sync_directory_skips_identical_files() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        let target = dir.path().join("target");

        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(source.join("a.md"), "same").unwrap();
        fs::write(target.join("a.md"), "same").unwrap();

        let before = fs::metadata(target.join("a.md"))
            .unwrap()
            .modified()
            .unwrap();
        // Small delay so mtime would differ if rewritten
        thread::sleep(Duration::from_millis(50));
        sync_directory(&source, &target).unwrap();
        let after = fs::metadata(target.join("a.md"))
            .unwrap()
            .modified()
            .unwrap();

        assert_eq!(before, after, "identical file should not be rewritten");
    }

    #[test]
    fn sync_directory_handles_subdirectories() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        let target = dir.path().join("target");

        let sub = source.join("nested");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("deep.md"), "deep content").unwrap();

        sync_directory(&source, &target).unwrap();

        assert_eq!(
            fs::read_to_string(target.join("nested").join("deep.md")).unwrap(),
            "deep content"
        );
    }

    #[test]
    fn sync_plugin_cache_updates_agents_in_cache() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");

        // Set up plugin source
        let plugin_dir = dir
            .path()
            .join("project")
            .join(".claude")
            .join("plugins")
            .join("suite");
        let source_agents = plugin_dir.join("agents");
        fs::create_dir_all(&source_agents).unwrap();
        fs::write(source_agents.join("writer.md"), "new agent def").unwrap();

        // Set up plugin.json
        let plugin_json_dir = plugin_dir.join(".claude-plugin");
        fs::create_dir_all(&plugin_json_dir).unwrap();
        fs::write(
            plugin_json_dir.join("plugin.json"),
            r#"{"name":"suite","version":"1.0.0"}"#,
        )
        .unwrap();

        // Set up stale cache
        let cache_agents = home
            .join(".claude")
            .join("plugins")
            .join("cache")
            .join("harness")
            .join("suite")
            .join("1.0.0")
            .join("agents");
        fs::create_dir_all(&cache_agents).unwrap();
        fs::write(cache_agents.join("writer.md"), "old agent def").unwrap();

        sync_plugin_cache(&plugin_dir, &home);

        assert_eq!(
            fs::read_to_string(cache_agents.join("writer.md")).unwrap(),
            "new agent def"
        );
    }

    #[test]
    fn sync_plugin_cache_skips_when_no_cache_dir() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");

        let plugin_dir = dir
            .path()
            .join("project")
            .join(".claude")
            .join("plugins")
            .join("suite");
        let source_agents = plugin_dir.join("agents");
        fs::create_dir_all(&source_agents).unwrap();
        fs::write(source_agents.join("a.md"), "content").unwrap();

        let plugin_json_dir = plugin_dir.join(".claude-plugin");
        fs::create_dir_all(&plugin_json_dir).unwrap();
        fs::write(
            plugin_json_dir.join("plugin.json"),
            r#"{"name":"suite","version":"1.0.0"}"#,
        )
        .unwrap();

        // No cache directory exists - should not panic
        sync_plugin_cache(&plugin_dir, &home);
    }

    #[test]
    fn lifecycle_commands_include_project_dirs() {
        assert_eq!(
            lifecycle_command(HookAgent::ClaudeCode, "session-start"),
            "harness session-start --project-dir \"$CLAUDE_PROJECT_DIR\""
        );
        assert_eq!(
            lifecycle_command(HookAgent::GeminiCli, "pre-compact"),
            "harness pre-compact --project-dir \"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\""
        );
        assert_eq!(
            lifecycle_command(HookAgent::Codex, "session-stop"),
            "harness session-stop --project-dir \"$PWD\""
        );
    }

    #[test]
    fn build_codex_config_includes_notify_and_hooks_flag() {
        let config = build_codex_config();
        assert!(config.contains("notify = [\"harness\", \"hook\", \"--agent\", \"codex\", \"suite:run\", \"audit-turn\"]"));
        assert!(config.contains("[features]\ncodex_hooks = true"));
    }

    #[test]
    fn build_opencode_bridge_replaces_placeholders_and_uses_directory() {
        let bridge = build_opencode_bridge(&BlockRegistry::production()).unwrap();
        assert!(!bridge.contains("__DENIED_BINARY_HINTS__"));
        assert!(!bridge.contains("__TOOL_GUARDS__"));
        assert!(!bridge.contains("__TOOL_VERIFIERS__"));
        assert!(bridge.contains("[\"session-start\", \"--project-dir\", directory]"));
        assert!(bridge.contains("[\"pre-compact\", \"--project-dir\", directory]"));
        assert!(bridge.contains("[\"session-stop\", \"--project-dir\", directory]"));
    }

    #[test]
    fn write_agent_bootstrap_writes_opencode_bridge_and_package() {
        let dir = tempfile::tempdir().unwrap();
        let written = write_agent_bootstrap(dir.path(), HookAgent::OpenCode).unwrap();

        let bridge_path = dir
            .path()
            .join(".opencode")
            .join("plugins")
            .join("harness-bridge.ts");
        let package_path = dir.path().join(".opencode").join("package.json");

        assert!(written.contains(&bridge_path));
        assert!(written.contains(&package_path));
        assert!(bridge_path.exists());
        assert!(package_path.exists());

        let bridge = fs::read_to_string(bridge_path).unwrap();
        assert!(bridge.contains("[\"session-start\", \"--project-dir\", directory]"));
    }

    fn assert_codex_hooks(hooks: &str) {
        assert!(hooks.contains("\"SessionStart\""));
        assert!(hooks.contains("\"Stop\""));
        assert!(!hooks.contains("guard-bash"));
    }

    #[test]
    fn write_agent_bootstrap_writes_codex_notify_config() {
        let dir = tempfile::tempdir().unwrap();
        let written = write_agent_bootstrap(dir.path(), HookAgent::Codex).unwrap();

        let hooks_path = dir.path().join(".codex").join("hooks.json");
        let config_path = dir.path().join(".codex").join("config.toml");

        assert!(written.contains(&hooks_path));
        assert!(written.contains(&config_path));

        assert_codex_hooks(&fs::read_to_string(hooks_path).unwrap());
        let config = fs::read_to_string(config_path).unwrap();
        assert!(config.contains("\"audit-turn\""));
        assert!(config.contains("codex_hooks = true"));
    }
}

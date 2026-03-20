use std::os::unix::fs::PermissionsExt;
use std::{thread, time::Duration};

use fs_err as fs;

use super::install::{install_wrapper, path_candidates};
use super::plugin_cache::{read_plugin_version, sync_directory, sync_plugin_cache};
use super::registrations::{build_codex_config, build_opencode_bridge, lifecycle_command};
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

    assert_eq!(
        read_plugin_version(dir.path()).unwrap(),
        Some("1.0.0".to_string())
    );
}

#[test]
fn read_plugin_version_returns_none_when_missing() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(read_plugin_version(dir.path()).unwrap(), None);
}

#[test]
fn read_plugin_version_rejects_invalid_json() {
    let dir = tempfile::tempdir().unwrap();
    let plugin_json_dir = dir.path().join(".claude-plugin");
    fs::create_dir_all(&plugin_json_dir).unwrap();
    fs::write(plugin_json_dir.join("plugin.json"), "{ invalid").unwrap();

    let error = read_plugin_version(dir.path()).unwrap_err();
    assert_eq!(error.code(), "KSRCLI019");
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

    let plugin_dir = dir
        .path()
        .join("project")
        .join(".claude")
        .join("plugins")
        .join("suite");
    let source_agents = plugin_dir.join("agents");
    fs::create_dir_all(&source_agents).unwrap();
    fs::write(source_agents.join("writer.md"), "new agent def").unwrap();

    let plugin_json_dir = plugin_dir.join(".claude-plugin");
    fs::create_dir_all(&plugin_json_dir).unwrap();
    fs::write(
        plugin_json_dir.join("plugin.json"),
        r#"{"name":"suite","version":"1.0.0"}"#,
    )
    .unwrap();

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

    sync_plugin_cache(&plugin_dir, &home).unwrap();

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

    sync_plugin_cache(&plugin_dir, &home).unwrap();
}

#[test]
fn lifecycle_commands_include_project_dirs() {
    assert_eq!(
        lifecycle_command(HookAgent::ClaudeCode, "session-start"),
        "harness setup session-start --project-dir \"$CLAUDE_PROJECT_DIR\""
    );
    assert_eq!(
        lifecycle_command(HookAgent::GeminiCli, "pre-compact"),
        "harness setup pre-compact --project-dir \"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\""
    );
    assert_eq!(
        lifecycle_command(HookAgent::Codex, "session-stop"),
        "harness setup session-stop --project-dir \"$PWD\""
    );
}

#[test]
fn build_codex_config_includes_notify_and_hooks_flag() {
    let config = build_codex_config();
    assert!(config.contains("\"audit-turn\""));
    assert!(config.contains("codex_hooks = true"));
}

#[test]
fn build_opencode_bridge_replaces_placeholders_and_uses_directory() {
    let bridge = build_opencode_bridge().unwrap();
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

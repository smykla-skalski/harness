use std::os::unix::fs::PermissionsExt;
use std::{thread, time::Duration};

use fs_err as fs;

use super::install::{install_wrapper, path_candidates};
use super::plugin_cache::{read_plugin_version, sync_directory, sync_plugin_cache};
use super::*;
use serde_json::Value;

mod bootstrap;

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
fn wrapper_content_walks_parent_directories() {
    assert!(WRAPPER.contains("resolve_from_cwd"));
}

#[test]
fn project_plugin_launcher_prefers_repo_build_then_path() {
    assert!(PROJECT_PLUGIN_LAUNCHER.contains("CLAUDE_PROJECT_DIR"));
    assert!(PROJECT_PLUGIN_LAUNCHER.contains("target/debug/harness"));
    assert!(PROJECT_PLUGIN_LAUNCHER.contains("command -v harness"));
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
fn choose_install_dir_falls_back_to_local_bin_when_local_dir_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let expected = dir
        .path()
        .canonicalize()
        .unwrap_or_else(|_| dir.path().to_path_buf())
        .join(".local")
        .join("bin");

    let (chosen, on_path) = choose_install_dir_with_home("/usr/bin:/bin", dir.path()).unwrap();

    assert_eq!(chosen, expected);
    assert!(!on_path);
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
fn main_materializes_plugin_when_missing() {
    let dir = tempfile::tempdir().unwrap();
    let bin_dir = dir.path().join(".local").join("bin");
    fs::create_dir_all(&bin_dir).unwrap();

    let path_env = bin_dir.to_string_lossy().into_owned();
    let result = main_with_home(dir.path(), &path_env, dir.path());

    assert_eq!(result.unwrap(), 0);
    assert!(bin_dir.join("harness").exists());
    assert!(
        dir.path()
            .join(".claude")
            .join("plugins")
            .join("suite")
            .join("harness")
            .exists()
    );
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
    fs::write(plugin_dir.join("harness"), "#!/bin/sh\necho launcher\n").unwrap();

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
    let cache_launcher = home
        .join(".claude")
        .join("plugins")
        .join("cache")
        .join("harness")
        .join("suite")
        .join("1.0.0")
        .join("harness");
    fs::write(&cache_launcher, "#!/bin/sh\necho stale\n").unwrap();

    sync_plugin_cache(&plugin_dir, &home).unwrap();

    assert_eq!(
        fs::read_to_string(cache_agents.join("writer.md")).unwrap(),
        "new agent def"
    );
    assert_eq!(
        fs::read_to_string(cache_launcher).unwrap(),
        "#!/bin/sh\necho launcher\n"
    );
}

#[test]
fn sync_plugin_cache_creates_cache_when_missing() {
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

    let cache_dir = home
        .join(".claude")
        .join("plugins")
        .join("cache")
        .join("harness")
        .join("suite")
        .join("1.0.0");
    assert!(cache_dir.is_dir(), "cache dir must be created");
    assert_eq!(
        fs::read_to_string(cache_dir.join("agents").join("a.md")).unwrap(),
        "content"
    );
}

#[test]
fn sync_plugin_cache_registers_in_installed_plugins() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");

    let plugin_dir = dir
        .path()
        .join("project")
        .join(".claude")
        .join("plugins")
        .join("council");
    let plugin_json_dir = plugin_dir.join(".claude-plugin");
    fs::create_dir_all(&plugin_json_dir).unwrap();
    fs::write(
        plugin_json_dir.join("plugin.json"),
        r#"{"name":"council","version":"1.1.0","description":"council"}"#,
    )
    .unwrap();

    let installed_path = home
        .join(".claude")
        .join("plugins")
        .join("installed_plugins.json");
    fs::create_dir_all(installed_path.parent().unwrap()).unwrap();
    fs::write(&installed_path, r#"{"version":2,"plugins":{}}"#).unwrap();

    sync_plugin_cache(&plugin_dir, &home).unwrap();

    let content = fs::read_to_string(&installed_path).unwrap();
    let parsed: Value = serde_json::from_str(&content).unwrap();
    let entry = &parsed["plugins"]["council@harness"][0];
    assert_eq!(entry["scope"], "user");
    assert_eq!(entry["version"], "1.1.0");
    let install_path = entry["installPath"].as_str().unwrap();
    assert!(
        install_path.contains("/harness/council/"),
        "installPath must contain /harness/council/, got: {install_path}"
    );
}

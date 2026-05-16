//! System-level defaults the daemon can offer the UI as placeholder values.
//!
//! These are purely read-side: nothing here mutates the user's environment.
//! The values are derived from `git config --global`, `gh auth`, the OpenSSH
//! key directory under `$HOME/.ssh`, and a small whitelist of environment
//! variables. None of the returned fields ever carry secret material — only
//! presence flags and non-sensitive metadata (paths, modes, public-key formats).

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitIdentityDefaults {
    pub git_config: TaskBoardGitConfigDefaults,
    pub gh_cli: TaskBoardGhCliDefaults,
    pub discovered_ssh_keys: Vec<TaskBoardSshKeyDiscovery>,
    pub env_overrides: TaskBoardEnvDefaults,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitConfigDefaults {
    pub user_name: Option<String>,
    pub user_email: Option<String>,
    pub user_signingkey: Option<String>,
    pub gpg_format: Option<String>,
    pub commit_gpgsign: Option<bool>,
    pub core_ssh_command: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGhCliDefaults {
    pub github_token_present: bool,
    pub username: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardSshKeyDiscovery {
    pub path: String,
    pub mode: String,
    pub format: Option<String>,
    pub warning: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardEnvDefaults {
    pub harness_github_token_present: bool,
    pub harness_todoist_token_present: bool,
}

pub fn discover() -> TaskBoardGitIdentityDefaults {
    use std::env;
    let home = env::var_os("HOME").map(PathBuf::from);
    let env_vars: HashMap<String, String> = env::vars().collect();
    TaskBoardGitIdentityDefaults {
        git_config: discover_git_config(),
        gh_cli: discover_gh_cli(),
        discovered_ssh_keys: discover_ssh_keys(home.as_deref()),
        env_overrides: discover_env_vars(&env_vars),
    }
}

fn discover_git_config() -> TaskBoardGitConfigDefaults {
    TaskBoardGitConfigDefaults {
        user_name: read_git_config("user.name"),
        user_email: read_git_config("user.email"),
        user_signingkey: read_git_config("user.signingkey"),
        gpg_format: read_git_config("gpg.format"),
        commit_gpgsign: read_git_config_bool("commit.gpgsign"),
        core_ssh_command: read_git_config("core.sshCommand"),
    }
}

fn read_git_config(key: &str) -> Option<String> {
    let output = Command::new("git")
        .args(["config", "--global", "--get", key])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    if value.is_empty() { None } else { Some(value) }
}

fn read_git_config_bool(key: &str) -> Option<bool> {
    read_git_config(key).and_then(|raw| parse_git_bool(&raw))
}

fn parse_git_bool(raw: &str) -> Option<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" | "" => Some(false),
        _ => None,
    }
}

fn discover_gh_cli() -> TaskBoardGhCliDefaults {
    let token_present = Command::new("gh")
        .args(["auth", "token"])
        .output()
        .is_ok_and(|out| out.status.success() && !out.stdout.is_empty());
    let username = if token_present {
        Command::new("gh")
            .args(["api", "user", "--jq", ".login"])
            .output()
            .ok()
            .filter(|out| out.status.success())
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .map(|raw| raw.trim().to_owned())
            .filter(|name| !name.is_empty())
    } else {
        None
    };
    TaskBoardGhCliDefaults {
        github_token_present: token_present,
        username,
    }
}

fn discover_ssh_keys(home: Option<&Path>) -> Vec<TaskBoardSshKeyDiscovery> {
    let Some(home) = home else { return Vec::new() };
    let ssh_dir = home.join(".ssh");
    let Ok(entries) = fs::read_dir(&ssh_dir) else {
        return Vec::new();
    };
    let mut keys = Vec::new();
    for entry in entries.flatten() {
        if let Some(key) = inspect_candidate_key(&entry.path(), home) {
            keys.push(key);
        }
    }
    keys.sort_by(|left, right| left.path.cmp(&right.path));
    keys
}

fn inspect_candidate_key(path: &Path, home: &Path) -> Option<TaskBoardSshKeyDiscovery> {
    let name = path.file_name()?.to_str()?;
    if !name.starts_with("id_") {
        return None;
    }
    if path.extension() == Some(OsStr::new("pub")) {
        return None;
    }
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mode = unix_mode_string(&meta);
    let warning = if mode_is_owner_only(&mode) {
        None
    } else {
        Some("permissions too open".to_owned())
    };
    Some(TaskBoardSshKeyDiscovery {
        path: render_home_relative(path, home),
        mode,
        format: read_public_key_format(path),
        warning,
    })
}

#[cfg(unix)]
fn unix_mode_string(meta: &fs::Metadata) -> String {
    use std::os::unix::fs::PermissionsExt;
    format!("0{:o}", meta.permissions().mode() & 0o7777)
}

#[cfg(not(unix))]
fn unix_mode_string(_meta: &fs::Metadata) -> String {
    "0000".to_owned()
}

fn mode_is_owner_only(mode: &str) -> bool {
    matches!(mode, "0600" | "0400")
}

fn read_public_key_format(private_path: &Path) -> Option<String> {
    let mut pub_path = private_path.to_path_buf();
    let mut pub_name = private_path.file_name()?.to_owned();
    pub_name.push(".pub");
    pub_path.set_file_name(pub_name);
    let bytes = fs::read(&pub_path).ok()?;
    let text = str::from_utf8(&bytes).ok()?;
    let alg = text.split_whitespace().next()?;
    Some(alg.trim_start_matches("ssh-").to_owned())
}

fn render_home_relative(path: &Path, home: &Path) -> String {
    path.strip_prefix(home).map_or_else(
        |_| path.display().to_string(),
        |rel| format!("~/{}", rel.display()),
    )
}

fn discover_env_vars(env: &HashMap<String, String>) -> TaskBoardEnvDefaults {
    TaskBoardEnvDefaults {
        harness_github_token_present: env_value_present(env, "HARNESS_GITHUB_TOKEN"),
        harness_todoist_token_present: env_value_present(env, "HARNESS_TODOIST_TOKEN"),
    }
}

fn env_value_present(env: &HashMap<String, String>, key: &str) -> bool {
    env.get(key).is_some_and(|value| !value.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn parse_git_bool_handles_truthy_and_falsy_forms() {
        assert_eq!(parse_git_bool("true"), Some(true));
        assert_eq!(parse_git_bool("YES"), Some(true));
        assert_eq!(parse_git_bool("on"), Some(true));
        assert_eq!(parse_git_bool("1"), Some(true));
        assert_eq!(parse_git_bool("false"), Some(false));
        assert_eq!(parse_git_bool("no"), Some(false));
        assert_eq!(parse_git_bool("0"), Some(false));
        assert_eq!(parse_git_bool(""), Some(false));
        assert_eq!(parse_git_bool("garbage"), None);
    }

    #[test]
    fn mode_is_owner_only_matches_0600_and_0400() {
        assert!(mode_is_owner_only("0600"));
        assert!(mode_is_owner_only("0400"));
        assert!(!mode_is_owner_only("0644"));
        assert!(!mode_is_owner_only("0700"));
        assert!(!mode_is_owner_only("0000"));
    }

    #[test]
    fn env_var_present_treats_blank_as_absent() {
        let mut env = HashMap::new();
        env.insert("HARNESS_GITHUB_TOKEN".to_owned(), "  ".to_owned());
        env.insert("HARNESS_TODOIST_TOKEN".to_owned(), "abc".to_owned());
        let defaults = discover_env_vars(&env);
        assert!(!defaults.harness_github_token_present);
        assert!(defaults.harness_todoist_token_present);
    }

    #[test]
    fn render_home_relative_substitutes_tilde() {
        let home = Path::new("/Users/bart");
        let key = Path::new("/Users/bart/.ssh/id_ed25519");
        assert_eq!(render_home_relative(key, home), "~/.ssh/id_ed25519");
    }

    #[test]
    fn render_home_relative_falls_back_for_outside_paths() {
        let home = Path::new("/Users/bart");
        let key = Path::new("/etc/ssh/ssh_host_key");
        assert_eq!(render_home_relative(key, home), "/etc/ssh/ssh_host_key");
    }

    #[test]
    fn discover_ssh_keys_returns_empty_when_no_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let keys = discover_ssh_keys(Some(tmp.path()));
        assert!(keys.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn discover_ssh_keys_finds_ed25519_with_owner_only_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let ssh = tmp.path().join(".ssh");
        fs::create_dir(&ssh).unwrap();
        write_key_pair(&ssh, "id_ed25519", "ssh-ed25519 AAAA fake", 0o600);
        let keys = discover_ssh_keys(Some(tmp.path()));
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].path, "~/.ssh/id_ed25519");
        assert_eq!(keys[0].mode, "0600");
        assert_eq!(keys[0].format.as_deref(), Some("ed25519"));
        assert!(keys[0].warning.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn discover_ssh_keys_warns_on_world_readable_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let ssh = tmp.path().join(".ssh");
        fs::create_dir(&ssh).unwrap();
        write_key_pair(&ssh, "id_rsa", "ssh-rsa AAAA fake", 0o644);
        let keys = discover_ssh_keys(Some(tmp.path()));
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].mode, "0644");
        assert_eq!(keys[0].warning.as_deref(), Some("permissions too open"));
    }

    #[cfg(unix)]
    #[test]
    fn discover_ssh_keys_skips_public_keys_and_non_id_files() {
        let tmp = tempfile::tempdir().unwrap();
        let ssh = tmp.path().join(".ssh");
        fs::create_dir(&ssh).unwrap();
        write_key_pair(&ssh, "id_ed25519", "ssh-ed25519 AAAA", 0o600);
        fs::write(ssh.join("config"), "Host *").unwrap();
        fs::write(ssh.join("known_hosts"), "").unwrap();
        let keys = discover_ssh_keys(Some(tmp.path()));
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].path, "~/.ssh/id_ed25519");
    }

    #[cfg(unix)]
    #[test]
    fn discover_ssh_keys_sorts_results_by_path() {
        let tmp = tempfile::tempdir().unwrap();
        let ssh = tmp.path().join(".ssh");
        fs::create_dir(&ssh).unwrap();
        write_key_pair(&ssh, "id_rsa", "ssh-rsa AAAA", 0o600);
        write_key_pair(&ssh, "id_ed25519", "ssh-ed25519 AAAA", 0o600);
        let keys = discover_ssh_keys(Some(tmp.path()));
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].path, "~/.ssh/id_ed25519");
        assert_eq!(keys[1].path, "~/.ssh/id_rsa");
    }

    #[cfg(unix)]
    fn write_key_pair(dir: &Path, name: &str, pub_contents: &str, mode: u32) {
        let priv_path = dir.join(name);
        fs::write(&priv_path, b"-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n").unwrap();
        let mut perms = fs::metadata(&priv_path).unwrap().permissions();
        perms.set_mode(mode);
        fs::set_permissions(&priv_path, perms).unwrap();
        fs::write(dir.join(format!("{name}.pub")), pub_contents.as_bytes()).unwrap();
    }
}

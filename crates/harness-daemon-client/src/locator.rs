use std::env;
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::sync::Mutex;

const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";
const DAEMON_OWNERSHIP_ENV: &str = "HARNESS_DAEMON_OWNERSHIP";
const HARNESS_MONITOR_APP_GROUP_ID: &str = "Q498EB36N4.io.harnessmonitor";
const RUNTIME_PROFILES_DIR: &str = "runtime-profiles";
const AGENT_PROFILE_PREFIX: &str = "agent-";

static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Read-only daemon state used by standalone clients.
pub mod state {
    use std::path::{Path, PathBuf};

    use fs2::FileExt as _;
    use serde::Deserialize;
    #[cfg(any(test, feature = "test-support"))]
    use serde::Serialize;

    use super::{DAEMON_ROOT_OVERRIDE, OpenOptions, base_daemon_dir, ownership};

    pub const DAEMON_LOCK_FILE: &str = "daemon.lock";

    #[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
    #[cfg_attr(any(test, feature = "test-support"), derive(Serialize))]
    pub struct DaemonManifest {
        pub endpoint: String,
        pub token_path: String,
    }

    #[derive(Debug, thiserror::Error)]
    pub enum StateError {
        #[error("read daemon manifest {}: {source}", path.display())]
        Read {
            path: PathBuf,
            source: std::io::Error,
        },
        #[error("decode daemon manifest {}: {source}", path.display())]
        Decode {
            path: PathBuf,
            source: serde_json::Error,
        },
        #[cfg(any(test, feature = "test-support"))]
        #[error("encode daemon manifest: {0}")]
        Encode(serde_json::Error),
        #[cfg(any(test, feature = "test-support"))]
        #[error("write daemon manifest {}: {source}", path.display())]
        Write {
            path: PathBuf,
            source: std::io::Error,
        },
    }

    #[cfg(any(test, feature = "test-support"))]
    pub struct ScopedDaemonRootOverride {
        previous: Option<PathBuf>,
    }

    #[cfg(any(test, feature = "test-support"))]
    impl ScopedDaemonRootOverride {
        /// Install a process-local daemon-root override until this guard drops.
        ///
        /// # Panics
        /// Panics if another thread poisoned the internal override mutex.
        #[must_use]
        pub fn set(root: Option<PathBuf>) -> Self {
            let mut current = DAEMON_ROOT_OVERRIDE
                .lock()
                .expect("daemon root override mutex poisoned");
            let previous = current.clone();
            *current = root;
            Self { previous }
        }
    }

    #[cfg(any(test, feature = "test-support"))]
    impl Drop for ScopedDaemonRootOverride {
        fn drop(&mut self) {
            DAEMON_ROOT_OVERRIDE
                .lock()
                .expect("daemon root override mutex poisoned")
                .clone_from(&self.previous);
        }
    }

    /// Resolve the effective daemon root for this process.
    ///
    /// # Panics
    /// Panics if another thread poisoned the internal override mutex.
    #[must_use]
    pub fn daemon_root() -> PathBuf {
        DAEMON_ROOT_OVERRIDE
            .lock()
            .expect("daemon root override mutex poisoned")
            .clone()
            .unwrap_or_else(default_daemon_root)
    }

    #[must_use]
    pub(super) fn default_daemon_root() -> PathBuf {
        base_daemon_dir().join(ownership())
    }

    pub(super) fn set_daemon_root_override(root: PathBuf) {
        *DAEMON_ROOT_OVERRIDE
            .lock()
            .expect("daemon root override mutex poisoned") = Some(root);
    }

    #[must_use]
    pub fn auth_token_path() -> PathBuf {
        daemon_root().join("auth-token")
    }

    #[must_use]
    pub fn daemon_lock_is_held_at(path: &Path) -> bool {
        let Ok(file) = OpenOptions::new().read(true).write(true).open(path) else {
            return false;
        };
        match file.try_lock_exclusive() {
            Ok(()) => {
                let _ = fs2::FileExt::unlock(&file);
                false
            }
            Err(error) => error.kind() == std::io::ErrorKind::WouldBlock,
        }
    }

    /// Load the manifest only while the daemon singleton lock is held.
    ///
    /// # Errors
    /// Returns an error when a live daemon manifest cannot be read or decoded.
    pub fn load_running_manifest() -> Result<Option<DaemonManifest>, StateError> {
        let root = daemon_root();
        if !daemon_lock_is_held_at(&root.join(DAEMON_LOCK_FILE)) {
            return Ok(None);
        }
        load_manifest_at(&root)
    }

    fn load_manifest_at(root: &Path) -> Result<Option<DaemonManifest>, StateError> {
        let path = root.join("manifest.json");
        if !path.is_file() {
            return Ok(None);
        }
        let bytes = std::fs::read(&path).map_err(|source| StateError::Read {
            path: path.clone(),
            source,
        })?;
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|source| StateError::Decode { path, source })
    }

    /// Acquire the singleton lock used by daemon discovery fixtures.
    ///
    /// # Errors
    /// Returns an error when the lock directory or file cannot be opened or locked.
    #[cfg(any(test, feature = "test-support"))]
    pub fn acquire_singleton_lock() -> Result<std::fs::File, std::io::Error> {
        let root = daemon_root();
        std::fs::create_dir_all(&root)?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(root.join(DAEMON_LOCK_FILE))?;
        file.try_lock_exclusive()?;
        Ok(file)
    }

    /// Write the minimal manifest used by client proxy fixtures.
    ///
    /// # Errors
    /// Returns an error when serialization or persistence fails.
    #[cfg(any(test, feature = "test-support"))]
    pub fn write_manifest(manifest: &DaemonManifest) -> Result<DaemonManifest, StateError> {
        let root = daemon_root();
        std::fs::create_dir_all(&root).map_err(|source| StateError::Write {
            path: root.clone(),
            source,
        })?;
        let bytes = serde_json::to_vec_pretty(manifest).map_err(StateError::Encode)?;
        let path = root.join("manifest.json");
        std::fs::write(&path, bytes).map_err(|source| StateError::Write { path, source })?;
        Ok(manifest.clone())
    }

    #[cfg(test)]
    mod tests {
        use fs2::FileExt as _;
        use tempfile::tempdir;

        use super::*;

        #[test]
        fn lock_probe_distinguishes_held_and_released_files() {
            let temp = tempdir().expect("tempdir");
            let path = temp.path().join(DAEMON_LOCK_FILE);
            let file = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(&path)
                .expect("open lock");
            file.try_lock_exclusive().expect("lock");
            assert!(daemon_lock_is_held_at(&path));
            fs2::FileExt::unlock(&file).expect("unlock");
            assert!(!daemon_lock_is_held_at(&path));
        }

        #[test]
        fn minimal_manifest_ignores_daemon_only_fields() {
            let temp = tempdir().expect("tempdir");
            std::fs::write(
                temp.path().join("manifest.json"),
                r#"{
                    "endpoint":"http://127.0.0.1:5173",
                    "token_path":"/tmp/token",
                    "pid":42,
                    "revision":9
                }"#,
            )
            .expect("write manifest");

            assert_eq!(
                load_manifest_at(temp.path()).expect("load manifest"),
                Some(DaemonManifest {
                    endpoint: "http://127.0.0.1:5173".to_string(),
                    token_path: "/tmp/token".to_string(),
                })
            );
        }
    }
}

/// Discovery and adoption of the live daemon root.
pub mod discovery {
    use std::path::{Path, PathBuf};

    use super::{
        AGENT_PROFILE_PREFIX, HARNESS_MONITOR_APP_GROUP_ID, RUNTIME_PROFILES_DIR, data_root,
        host_home_dir, ownership, state,
    };

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum AdoptionOutcome {
        AlreadyCoherent { root: PathBuf },
        Adopted { from: PathBuf, to: PathBuf },
        NoRunningDaemon { default_root: PathBuf },
    }

    #[derive(Debug, PartialEq, Eq)]
    enum ProfileFamily {
        Agent(String),
        NonAgent,
    }

    #[must_use]
    pub fn adopt_running_daemon_root() -> AdoptionOutcome {
        let effective_root = state::daemon_root();
        if root_is_live(&effective_root) {
            return AdoptionOutcome::AlreadyCoherent {
                root: effective_root,
            };
        }

        let own_family = profile_family(&effective_root);
        for candidate in candidate_roots() {
            if candidate == effective_root || profile_family(&candidate) != own_family {
                continue;
            }
            if root_is_live(&candidate) {
                state::set_daemon_root_override(candidate.clone());
                return AdoptionOutcome::Adopted {
                    from: effective_root,
                    to: candidate,
                };
            }
        }
        AdoptionOutcome::NoRunningDaemon {
            default_root: effective_root,
        }
    }

    fn root_is_live(root: &Path) -> bool {
        state::daemon_lock_is_held_at(&root.join(state::DAEMON_LOCK_FILE))
    }

    fn candidate_roots() -> Vec<PathBuf> {
        let ownership = ownership();
        let mut roots = vec![state::default_daemon_root()];
        if cfg!(target_os = "macos") {
            push_unique(
                &mut roots,
                host_home_dir()
                    .join("Library")
                    .join("Group Containers")
                    .join(HARNESS_MONITOR_APP_GROUP_ID)
                    .join("harness")
                    .join("daemon")
                    .join(ownership),
            );
        }
        push_unique(
            &mut roots,
            data_root().join("harness").join("daemon").join(ownership),
        );
        roots
    }

    fn push_unique(roots: &mut Vec<PathBuf>, root: PathBuf) {
        if !roots.contains(&root) {
            roots.push(root);
        }
    }

    fn profile_family(root: &Path) -> ProfileFamily {
        let mut components = root.components();
        while let Some(component) = components.next() {
            if component.as_os_str() == RUNTIME_PROFILES_DIR
                && let Some(profile) = components.next()
                && let Some(agent) = profile
                    .as_os_str()
                    .to_string_lossy()
                    .strip_prefix(AGENT_PROFILE_PREFIX)
            {
                return ProfileFamily::Agent(agent.to_string());
            }
        }
        ProfileFamily::NonAgent
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn agent_profiles_are_isolated_by_identifier() {
            assert_eq!(
                profile_family(Path::new("/tmp/runtime-profiles/agent-one/harness/daemon")),
                ProfileFamily::Agent("one".to_string())
            );
            assert_ne!(
                profile_family(Path::new("/tmp/runtime-profiles/agent-one/harness/daemon")),
                profile_family(Path::new("/tmp/runtime-profiles/agent-two/harness/daemon"))
            );
            assert_eq!(
                profile_family(Path::new("/tmp/runtime-profiles/user/harness/daemon")),
                ProfileFamily::NonAgent
            );
        }
    }
}

fn base_daemon_dir() -> PathBuf {
    if let Some(root) = normalized_env(DAEMON_DATA_HOME_ENV) {
        return PathBuf::from(root).join("harness").join("daemon");
    }
    if let Some(group_id) = normalized_env(APP_GROUP_ID_ENV) {
        return host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(group_id)
            .join("harness")
            .join("daemon");
    }
    data_root().join("harness").join("daemon")
}

fn ownership() -> &'static str {
    match normalized_env(DAEMON_OWNERSHIP_ENV)
        .as_deref()
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("external") => "external",
        _ => "managed",
    }
}

fn data_root() -> PathBuf {
    normalized_env("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| user_dirs::data_dir().ok())
        .unwrap_or_else(|| host_home_dir().join(".local").join("share"))
}

fn host_home_dir() -> PathBuf {
    normalized_env("HARNESS_HOST_HOME")
        .map(PathBuf::from)
        .or_else(account_home_dir)
        .or_else(|| normalized_env("HOME").map(PathBuf::from))
        .or_else(|| user_dirs::home_dir().ok())
        .unwrap_or_else(|| env::temp_dir().join(format!("harness-{}", uzers::get_current_uid())))
}

#[cfg(unix)]
fn account_home_dir() -> Option<PathBuf> {
    use uzers::os::unix::UserExt as _;

    uzers::get_user_by_uid(uzers::get_current_uid()).map(|user| user.home_dir().to_path_buf())
}

#[cfg(not(unix))]
fn account_home_dir() -> Option<PathBuf> {
    None
}

fn normalized_env(name: &str) -> Option<String> {
    let value = env::var(name).ok()?;
    let value = value.trim();
    if value.is_empty()
        || value.eq_ignore_ascii_case("unset")
        || value.starts_with("${") && value.ends_with('}')
    {
        return None;
    }
    Some(value.to_string())
}

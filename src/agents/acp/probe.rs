use std::io;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::{LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub use harness_protocol::managed_agents::acp::{
    AcpAuthState, AcpRuntimeProbe, AcpRuntimeProbeResponse,
};
use tracing::warn;

use crate::workspace::{account_home_dir, dirs_home, normalized_env_value, utc_now};

use super::catalog::{AcpAgentDescriptor, acp_agents};
use super::program::resolve_program;

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const PROBE_CACHE_TTL: Duration = Duration::from_secs(30);
/// Redirects the HOME handed to probed agent binaries. Tests point this at one
/// reusable directory; `harness_testkit::env` owns that path.
const PROBE_HOME_ENV: &str = "HARNESS_AGENT_PROBE_HOME";

#[derive(Clone)]
struct ProbeCacheEntry {
    cached_at: Instant,
    response: AcpRuntimeProbeResponse,
}

#[derive(Default)]
struct ProbeCacheState {
    entry: Option<ProbeCacheEntry>,
    refreshing: bool,
}

static PROBE_CACHE: LazyLock<Mutex<ProbeCacheState>> =
    LazyLock::new(|| Mutex::new(ProbeCacheState::default()));

// Refreshing the cache can mean asking a host process instead of probing
// locally, but only a sandboxed daemon can be in that situation. That choice
// therefore belongs to the daemon and reaches this module as `spawn_refresh`;
// nothing here may look at the daemon to decide for itself.

/// The right to publish one in-flight refresh, held by whoever is performing it.
///
/// Dropping this without storing a response releases the cache instead of
/// publishing, so a panicking refresh thread, a thread that never started, or an
/// early return all leave the cache open to the next caller. Nothing else may
/// clear the in-flight flag, which is what keeps a wedged cache impossible
/// rather than merely unlikely.
pub(crate) struct ProbeCacheRefresh {
    published: bool,
}

impl ProbeCacheRefresh {
    /// Publish `response` as the current snapshot and end the refresh.
    ///
    /// # Panics
    /// Panics if the process-wide probe cache mutex is poisoned.
    pub(crate) fn publish(mut self, response: AcpRuntimeProbeResponse) {
        let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
        cache.entry = Some(ProbeCacheEntry {
            cached_at: Instant::now(),
            response,
        });
        cache.refreshing = false;
        self.published = true;
    }
}

impl Drop for ProbeCacheRefresh {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
        cache.refreshing = false;
    }
}

/// Return the latest process-local probe snapshot, scheduling a background
/// refresh in this process when needed.
#[must_use]
pub(crate) fn local_cached_probe_snapshot() -> Option<AcpRuntimeProbeResponse> {
    cached_probe_snapshot_with(spawn_local_probe_cache_refresh)
}

/// Return the latest cached ACP probe results without blocking request paths.
///
/// Fresh cache entries are returned directly. Stale entries are returned
/// immediately while `spawn_refresh` runs a background refresh. When no cached
/// data is available yet, this returns `None` and schedules the first refresh.
///
/// # Panics
/// Panics if the process-wide probe cache mutex is poisoned.
#[must_use]
pub(crate) fn cached_probe_snapshot_with(
    spawn_refresh: fn(ProbeCacheRefresh),
) -> Option<AcpRuntimeProbeResponse> {
    let mut should_refresh = false;
    let snapshot = {
        let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
        let cached = cache
            .entry
            .as_ref()
            .map(|entry| (probe_cache_entry_is_fresh(entry), entry.response.clone()));
        match cached {
            Some((true, response)) => Some(response),
            Some((false, response)) => {
                if !cache.refreshing {
                    cache.refreshing = true;
                    should_refresh = true;
                }
                Some(response)
            }
            None => {
                if !cache.refreshing {
                    cache.refreshing = true;
                    should_refresh = true;
                }
                None
            }
        }
    };

    if should_refresh {
        spawn_refresh(ProbeCacheRefresh { published: false });
    }

    snapshot
}

#[must_use]
pub fn probe_acp_agents() -> AcpRuntimeProbeResponse {
    let checked_at = utc_now();
    let probes = acp_agents()
        .into_iter()
        .map(probe_descriptor)
        .collect::<Vec<_>>();
    AcpRuntimeProbeResponse { probes, checked_at }
}

#[must_use]
pub fn probe_descriptor(descriptor: &AcpAgentDescriptor) -> AcpRuntimeProbe {
    let output = run_probe_command(descriptor);
    match output {
        Ok(output) if output.status.success() => AcpRuntimeProbe {
            agent_id: descriptor.id.clone(),
            display_name: descriptor.display_name.clone(),
            binary_present: true,
            auth_state: AcpAuthState::Unknown,
            version: version_from_output(&output.stdout, &output.stderr),
            install_hint: descriptor.install_hint.clone(),
        },
        Ok(output) => AcpRuntimeProbe {
            agent_id: descriptor.id.clone(),
            display_name: descriptor.display_name.clone(),
            binary_present: true,
            auth_state: AcpAuthState::Unavailable,
            version: version_from_output(&output.stdout, &output.stderr),
            install_hint: descriptor.install_hint.clone(),
        },
        Err(_) => AcpRuntimeProbe {
            agent_id: descriptor.id.clone(),
            display_name: descriptor.display_name.clone(),
            binary_present: false,
            auth_state: AcpAuthState::Unavailable,
            version: None,
            install_hint: descriptor.install_hint.clone(),
        },
    }
}

fn run_probe_command(descriptor: &AcpAgentDescriptor) -> io::Result<Output> {
    let program = resolve_program(&descriptor.doctor_probe.command)?;
    // The refresh thread is detached, so a probe can outlive a caller that
    // pointed HOME at a temp dir. Agents that bootstrap a package cache on
    // first run would download it there, after that dir was already removed,
    // leaving hundreds of megabytes nothing ever cleans up.
    let mut child = Command::new(program)
        .args(&descriptor.doctor_probe.args)
        .env("HOME", probe_home())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started_at = Instant::now();
    while started_at.elapsed() < PROBE_TIMEOUT {
        if child.try_wait()?.is_some() {
            return child.wait_with_output();
        }
        thread::sleep(Duration::from_millis(10));
    }
    let _ = child.kill();
    child.wait_with_output()
}

fn probe_home() -> PathBuf {
    normalized_env_value(PROBE_HOME_ENV).map_or_else(default_probe_home, PathBuf::from)
}

// Package caches belong to the OS account, so this deliberately skips
// HARNESS_HOST_HOME. Resolving through it would aim a probe at whatever temp
// home the caller redirected to, and the download then lands in a directory
// that caller deletes moments later.
fn agent_package_home() -> PathBuf {
    account_home_dir().unwrap_or_else(dirs_home)
}

// Not every test reaches the probe through `with_isolated_harness_env`; some set
// HOME directly. Defaulting the whole test build to the shared directory keeps
// the developer's real home out of reach either way.
#[cfg(test)]
fn default_probe_home() -> PathBuf {
    harness_testkit::shared_agent_probe_home()
}

#[cfg(not(test))]
fn default_probe_home() -> PathBuf {
    agent_package_home()
}

fn probe_cache_entry_is_fresh(entry: &ProbeCacheEntry) -> bool {
    entry.cached_at.elapsed() < PROBE_CACHE_TTL
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn spawn_local_probe_cache_refresh(refresh: ProbeCacheRefresh) {
    if let Err(error) = spawn_local_probe_cache_refresh_thread(refresh) {
        warn!(%error, "failed to spawn ACP runtime probe refresh");
    }
}

fn spawn_local_probe_cache_refresh_thread(refresh: ProbeCacheRefresh) -> io::Result<()> {
    thread::Builder::new()
        .name("acp-probe-refresh".to_string())
        .spawn(move || refresh.publish(probe_acp_agents()))?;
    Ok(())
}

fn version_from_output(stdout: &[u8], stderr: &[u8]) -> Option<String> {
    let text = if stdout.is_empty() { stderr } else { stdout };
    let version = String::from_utf8_lossy(text);
    let version = version.lines().next()?.trim();
    (!version.is_empty()).then(|| version.to_string())
}

#[cfg(test)]
static PROBE_CACHE_TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[cfg(test)]
pub(crate) fn lock_probe_cache_for_tests() -> std::sync::MutexGuard<'static, ()> {
    PROBE_CACHE_TEST_LOCK
        .lock()
        .expect("ACP probe cache test lock")
}

#[cfg(test)]
pub(crate) fn replace_probe_cache_for_tests(
    response: Option<AcpRuntimeProbeResponse>,
    age: Duration,
    refreshing: bool,
) {
    let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
    cache.entry = response.map(|response| ProbeCacheEntry {
        cached_at: Instant::now() - age,
        response,
    });
    cache.refreshing = refreshing;
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use crate::agents::acp::catalog::{DoctorProbe, tags};

    fn descriptor(command: &str, args: &[&str]) -> AcpAgentDescriptor {
        AcpAgentDescriptor {
            id: "fake".to_string(),
            display_name: "Fake ACP".to_string(),
            capabilities: vec![tags::STREAMING.to_string()],
            launch_command: command.to_string(),
            launch_args: Vec::new(),
            env_passthrough: Vec::new(),
            spawn_configuration: Default::default(),
            model_catalog: None,
            install_hint: Some("install fake".to_string()),
            session_configuration: Default::default(),
            doctor_probe: DoctorProbe {
                command: command.to_string(),
                args: args.iter().map(ToString::to_string).collect(),
            },
            prompt_timeout_seconds: None,
            excluded_from_initial_default: false,
            bundled_with_harness: false,
        }
    }

    #[test]
    fn probe_descriptor_reports_missing_binary() {
        let probe = probe_descriptor(&descriptor("definitely-not-a-harness-acp-binary", &[]));
        assert!(!probe.binary_present);
        assert_eq!(probe.auth_state, AcpAuthState::Unavailable);
        assert_eq!(probe.install_hint.as_deref(), Some("install fake"));
    }

    #[test]
    fn probe_descriptor_captures_version_from_stdout() {
        let probe = probe_descriptor(&descriptor("printf", &["fake 1.2.3\n"]));
        assert!(probe.binary_present);
        assert_eq!(probe.version.as_deref(), Some("fake 1.2.3"));
    }

    #[cfg(unix)]
    #[test]
    fn probe_never_uses_a_path_decoy_for_a_managed_program() {
        use std::os::unix::fs::PermissionsExt;

        let path_dir = tempfile::tempdir().expect("path tempdir");
        let command = "harness-probe-path-decoy-781e91c9";
        let binary = path_dir.path().join(command);
        fs_err::write(&binary, "#!/bin/sh\nprintf 'decoy 1.0.0\\n'\n").expect("write path decoy");
        let mut permissions = binary.metadata().expect("decoy metadata").permissions();
        permissions.set_mode(0o755);
        fs_err::set_permissions(&binary, permissions).expect("make path decoy executable");

        let probe = temp_env::with_var(
            "PATH",
            Some(path_dir.path().to_str().expect("path tempdir string")),
            || probe_descriptor(&descriptor(command, &[])),
        );

        assert!(!probe.binary_present);
        assert_eq!(probe.auth_state, AcpAuthState::Unavailable);
        assert_eq!(probe.version, None);
    }

    #[cfg(unix)]
    #[test]
    fn probe_hands_agents_the_shared_home_not_an_isolated_one() {
        use std::os::unix::fs::PermissionsExt;
        use std::path::Path;

        let bin_dir = tempfile::tempdir().expect("probe bin tempdir");
        let command = "acp-probe-home-echo-4d2f81ab";
        let binary = bin_dir.path().join(command);
        fs_err::write(&binary, "#!/bin/sh\nprintf '%s\\n' \"$HOME\"\n").expect("write home echo");
        let mut permissions = binary.metadata().expect("home echo metadata").permissions();
        permissions.set_mode(0o755);
        fs_err::set_permissions(&binary, permissions).expect("make home echo executable");

        let shared_home = harness_testkit::shared_agent_probe_home();
        let isolated_home = tempfile::tempdir().expect("isolated home tempdir");
        let probe = temp_env::with_vars(
            [
                ("PATH", Some(bin_dir.path().to_str().expect("bin dir path"))),
                (
                    "HOME",
                    Some(isolated_home.path().to_str().expect("isolated home path")),
                ),
                (
                    PROBE_HOME_ENV,
                    Some(shared_home.to_str().expect("shared home path")),
                ),
            ],
            || probe_descriptor(&descriptor(command, &[])),
        );

        let reported = probe.version.expect("probe reports the child HOME");
        assert_ne!(
            Path::new(&reported),
            isolated_home.path(),
            "a probed agent that inherits an isolated HOME caches its package into a temp dir that outlives the caller"
        );
        assert_eq!(Path::new(&reported), shared_home);
    }

    #[test]
    fn probe_home_never_defaults_to_the_developers_home() {
        temp_env::with_var(PROBE_HOME_ENV, None::<&str>, || {
            let home = probe_home();
            assert_eq!(home, harness_testkit::shared_agent_probe_home());
            assert_ne!(
                home,
                agent_package_home(),
                "a test that probes with the real home downloads agent package caches into it"
            );
        });
    }

    #[test]
    fn agent_package_home_ignores_a_redirected_host_home() {
        let redirected = tempfile::tempdir().expect("redirected host home tempdir");
        temp_env::with_vars(
            [
                ("HARNESS_HOST_HOME", Some(redirected.path())),
                ("HOME", Some(redirected.path())),
            ],
            || {
                assert_ne!(
                    agent_package_home(),
                    redirected.path(),
                    "spawned binaries would download agent packages into a temp host home that the test then removes"
                );
            },
        );
    }

    #[test]
    fn cached_probe_snapshot_returns_seeded_entry_without_refreshing() {
        let _guard = lock_probe_cache_for_tests();
        let response = AcpRuntimeProbeResponse {
            probes: vec![AcpRuntimeProbe {
                agent_id: "copilot".to_string(),
                display_name: "GitHub Copilot".to_string(),
                binary_present: true,
                auth_state: AcpAuthState::Ready,
                version: Some("1.0.0".to_string()),
                install_hint: None,
            }],
            checked_at: "2026-05-03T20:00:00Z".to_string(),
        };
        replace_probe_cache_for_tests(Some(response.clone()), Duration::ZERO, false);

        assert_eq!(local_cached_probe_snapshot(), Some(response));

        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }

    static ABANDONED_REFRESH_CALLS: AtomicUsize = AtomicUsize::new(0);

    fn abandon_refresh(_refresh: ProbeCacheRefresh) {
        ABANDONED_REFRESH_CALLS.fetch_add(1, Ordering::SeqCst);
    }

    #[test]
    fn an_abandoned_refresh_releases_the_cache_for_the_next_caller() {
        let _guard = lock_probe_cache_for_tests();
        replace_probe_cache_for_tests(None, Duration::ZERO, false);
        ABANDONED_REFRESH_CALLS.store(0, Ordering::SeqCst);

        // Dropping the handle without publishing stands in for a refresh thread
        // that panics or never starts.
        assert_eq!(cached_probe_snapshot_with(abandon_refresh), None);
        assert_eq!(cached_probe_snapshot_with(abandon_refresh), None);

        assert_eq!(
            ABANDONED_REFRESH_CALLS.load(Ordering::SeqCst),
            2,
            "an abandoned refresh left the cache permanently marked as refreshing"
        );

        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }
}

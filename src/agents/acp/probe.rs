use std::io;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::{LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::workspace::utc_now;

use super::catalog::{AcpAgentDescriptor, acp_agents};
use super::program::resolve_program;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpRuntimeProbeResponse {
    pub probes: Vec<AcpRuntimeProbe>,
    pub checked_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpRuntimeProbe {
    pub agent_id: String,
    pub display_name: String,
    pub binary_present: bool,
    pub auth_state: AcpAuthState,
    pub version: Option<String>,
    pub install_hint: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AcpAuthState {
    Ready,
    Unknown,
    Unavailable,
}

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const PROBE_CACHE_TTL: Duration = Duration::from_secs(30);

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

/// Return cached ACP probe results for the current daemon process.
///
/// # Panics
/// Panics if the process-wide probe cache mutex is poisoned.
#[must_use]
pub fn probe_acp_agents_cached() -> AcpRuntimeProbeResponse {
    cached_probe_snapshot().unwrap_or_else(pending_probe_response)
}

/// Return the latest cached ACP probe results without blocking request paths.
///
/// Fresh cache entries are returned directly. Stale entries are returned
/// immediately while a background refresh runs. When no cached data is
/// available yet, this returns `None` and schedules the first refresh.
///
/// # Panics
/// Panics if the process-wide probe cache mutex is poisoned.
#[must_use]
pub fn cached_probe_snapshot() -> Option<AcpRuntimeProbeResponse> {
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
        spawn_probe_cache_refresh();
    }

    snapshot
}

/// Best-effort cache warm-up for the ACP runtime probe.
///
/// # Panics
/// Panics if the process-wide probe cache mutex is poisoned.
pub fn schedule_probe_cache_refresh() {
    let should_refresh = {
        let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
        let entry_is_fresh = cache.entry.as_ref().is_some_and(probe_cache_entry_is_fresh);
        if entry_is_fresh || cache.refreshing {
            false
        } else {
            cache.refreshing = true;
            true
        }
    };

    if should_refresh {
        spawn_probe_cache_refresh();
    }
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
    let program = resolve_program(&descriptor.doctor_probe.command)
        .unwrap_or_else(|| PathBuf::from(&descriptor.doctor_probe.command));
    let mut child = Command::new(program)
        .args(&descriptor.doctor_probe.args)
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

fn pending_probe_response() -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse {
        probes: Vec::new(),
        checked_at: utc_now(),
    }
}

fn probe_cache_entry_is_fresh(entry: &ProbeCacheEntry) -> bool {
    entry.cached_at.elapsed() < PROBE_CACHE_TTL
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn spawn_probe_cache_refresh() {
    if let Err(error) = spawn_probe_cache_refresh_thread() {
        clear_probe_cache_refresh_flag();
        warn!(%error, "failed to spawn ACP runtime probe refresh");
    }
}

fn spawn_probe_cache_refresh_thread() -> io::Result<()> {
    thread::Builder::new()
        .name("acp-probe-refresh".to_string())
        .spawn(|| {
            let response = probe_acp_agents();
            store_probe_cache(response);
        })?;
    Ok(())
}

fn clear_probe_cache_refresh_flag() {
    let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
    cache.refreshing = false;
}

fn store_probe_cache(response: AcpRuntimeProbeResponse) {
    let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
    cache.entry = Some(ProbeCacheEntry {
        cached_at: Instant::now(),
        response,
    });
    cache.refreshing = false;
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
            model_catalog: None,
            install_hint: Some("install fake".to_string()),
            doctor_probe: DoctorProbe {
                command: command.to_string(),
                args: args.iter().map(ToString::to_string).collect(),
            },
            prompt_timeout_seconds: None,
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

        assert_eq!(cached_probe_snapshot(), Some(response));

        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }

    #[test]
    fn cached_probe_returns_pending_response_while_refresh_is_in_flight() {
        let _guard = lock_probe_cache_for_tests();
        replace_probe_cache_for_tests(None, Duration::ZERO, true);

        let response = probe_acp_agents_cached();

        assert!(response.probes.is_empty());
        assert!(!response.checked_at.is_empty());

        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }
}

use std::io;
use std::process::{Command, Output, Stdio};
use std::sync::{LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::workspace::utc_now;

use super::catalog::{AcpAgentDescriptor, acp_agents};

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

static PROBE_CACHE: LazyLock<Mutex<Option<ProbeCacheEntry>>> = LazyLock::new(|| Mutex::new(None));

/// Return cached ACP probe results for the current daemon process.
///
/// # Panics
/// Panics if the process-wide probe cache mutex is poisoned.
#[must_use]
pub fn probe_acp_agents_cached() -> AcpRuntimeProbeResponse {
    let mut cache = PROBE_CACHE.lock().expect("ACP probe cache lock");
    if let Some(entry) = cache.as_ref()
        && entry.cached_at.elapsed() < PROBE_CACHE_TTL
    {
        return entry.response.clone();
    }
    let response = probe_acp_agents();
    *cache = Some(ProbeCacheEntry {
        cached_at: Instant::now(),
        response: response.clone(),
    });
    response
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
    let mut child = Command::new(&descriptor.doctor_probe.command)
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

fn version_from_output(stdout: &[u8], stderr: &[u8]) -> Option<String> {
    let text = if stdout.is_empty() { stderr } else { stdout };
    let version = String::from_utf8_lossy(text);
    let version = version.lines().next()?.trim();
    (!version.is_empty()).then(|| version.to_string())
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
}

use super::*;

#[derive(Debug, Clone)]
pub(super) struct ResolvedBridgeConfig {
    pub(super) persisted: PersistedBridgeConfig,
    pub(super) capabilities: BTreeSet<BridgeCapability>,
    pub(super) socket_path: PathBuf,
    pub(super) codex_port: u16,
    pub(super) codex_binary: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeCodexMetadata {
    pub(super) port: u16,
    pub(super) binary_path: String,
    #[serde(default)]
    pub(super) version: Option<String>,
    #[serde(default)]
    pub(super) last_exit_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAgentTuiMetadata {
    pub(super) active_sessions: usize,
}

#[derive(Debug, Clone)]
pub(super) struct BridgeSnapshotContext {
    pub(super) session_id: String,
    pub(super) agent_id: String,
    pub(super) tui_id: String,
    pub(super) profile: AgentTuiLaunchProfile,
    pub(super) project_dir: PathBuf,
    pub(super) transcript_path: PathBuf,
}

impl BridgeSnapshotContext {
    pub(super) fn borrowed(&self) -> AgentTuiSnapshotContext<'_> {
        AgentTuiSnapshotContext {
            session_id: &self.session_id,
            agent_id: &self.agent_id,
            tui_id: &self.tui_id,
            profile: &self.profile,
            project_dir: &self.project_dir,
            transcript_path: &self.transcript_path,
        }
    }
}

#[derive(Clone)]
pub(super) struct BridgeActiveTui {
    pub(super) process: Arc<AgentTuiProcess>,
    pub(super) context: BridgeSnapshotContext,
    pub(super) created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeEnvelope {
    pub(super) token: String,
    pub(super) request: BridgeRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub(super) enum BridgeRequest {
    Status,
    Shutdown,
    Reconfigure {
        request: BridgeReconfigureSpec,
    },
    Capability {
        capability: String,
        action: String,
        #[serde(default)]
        payload: Value,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeResponse {
    pub(super) ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) payload: Option<Value>,
}

impl BridgeResponse {
    pub(super) fn ok_payload<T: Serialize>(payload: &T) -> Result<Self, CliError> {
        let payload = serde_json::to_value(payload)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        Ok(Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: Some(payload),
        })
    }

    pub(super) const fn empty_ok() -> Self {
        Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: None,
        }
    }

    pub(super) fn error(error: &CliError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_string()),
            message: Some(error.message()),
            details: error.details().map(str::to_owned),
            payload: None,
        }
    }
}

pub(super) struct BridgeCodexProcess {
    pub(super) child: Child,
    pub(super) endpoint: String,
    pub(super) metadata: BridgeCodexMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CodexEndpointScheme {
    WebSocket,
    SecureWebSocket,
}

impl CodexEndpointScheme {
    pub(super) fn parse(endpoint: &str) -> Option<(Self, &str)> {
        endpoint
            .strip_prefix("ws://")
            .map(|address| (Self::WebSocket, address))
            .or_else(|| {
                endpoint
                    .strip_prefix("wss://")
                    .map(|address| (Self::SecureWebSocket, address))
            })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeReconfigureSpec {
    #[serde(default)]
    pub(super) enable: Vec<BridgeCapability>,
    #[serde(default)]
    pub(super) disable: Vec<BridgeCapability>,
    #[serde(default)]
    pub(super) force: bool,
}

impl BridgeReconfigureSpec {
    pub(super) fn validate(&self) -> Result<(), CliError> {
        if self.enable.is_empty() && self.disable.is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure requires at least one --enable or --disable flag",
            )
            .into());
        }
        let enable: BTreeSet<_> = self.enable.iter().copied().collect();
        if enable.len() != self.enable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --enable",
            )
            .into());
        }
        let disable: BTreeSet<_> = self.disable.iter().copied().collect();
        if disable.len() != self.disable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --disable",
            )
            .into());
        }
        if let Some(contradiction) = enable.intersection(&disable).next().copied() {
            return Err(CliErrorKind::workflow_parse(format!(
                "bridge reconfigure cannot enable and disable '{}' in one request",
                contradiction.name()
            ))
            .into());
        }
        Ok(())
    }

    #[must_use]
    pub(super) fn enable_set(&self) -> BTreeSet<BridgeCapability> {
        self.enable.iter().copied().collect()
    }

    #[must_use]
    pub(super) fn disable_set(&self) -> BTreeSet<BridgeCapability> {
        self.disable.iter().copied().collect()
    }

    pub(super) fn from_names(
        enable: &[String],
        disable: &[String],
        force: bool,
    ) -> Result<Self, CliError> {
        let enable = enable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let disable = disable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let request = Self {
            enable,
            disable,
            force,
        };
        request.validate()?;
        Ok(request)
    }
}

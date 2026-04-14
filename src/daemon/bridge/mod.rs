use std::collections::{BTreeMap, BTreeSet};
use std::env::{current_exe, split_paths, var, var_os};
use std::fmt;
use std::fs::Permissions;
use std::fs::{File, Metadata};
use std::io::{BufRead, BufReader, ErrorKind, Write as _};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio, id as process_id};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use clap::{Args, Subcommand, ValueEnum};
use fs_err as fs;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::utc_now;

use super::agent_tui::{
    AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiProcess, AgentTuiResizeRequest,
    AgentTuiSize, AgentTuiSnapshot, AgentTuiSnapshotContext, AgentTuiStatus,
    deliver_deferred_prompts, snapshot_from_process, spawn_agent_tui_process,
};
use super::discovery::{self, AdoptionOutcome};
use super::state::{self, HostBridgeCapabilityManifest, HostBridgeManifest};

mod agent_tui;
mod bridge_state;
mod capability_lifecycle;
mod client;
mod commands;
mod control;
mod core;
mod detached;
mod helpers;
mod runtime;
mod server;
mod types;

use bridge_state::{
    BridgeProof, ResolvedRunningBridge, bridge_lock_is_held, bridge_lock_path, clear_bridge_state,
    read_bridge_config, resolve_running_bridge, write_bridge_config, write_bridge_state,
};
use client::{BridgeGetRequest, BridgeInputRequest, BridgeResizeRequest};
use core::{
    BridgeActiveTui, BridgeAgentTuiMetadata, BridgeCodexMetadata, BridgeCodexProcess,
    BridgeEnvelope, BridgeReconfigureSpec, BridgeRequest, BridgeResponse, BridgeSnapshotContext,
    CodexEndpointScheme, ResolvedBridgeConfig,
};
use detached::{bridge_response_error, start_detached, wait_until_bridge_dead};
use helpers::{
    best_effort_bootout, bootstrap_agent, cleanup_legacy_bridge_artifacts, detect_codex_version,
    launch_agent_plist_path, merged_persisted_config, parse_bridge_payload, print_json,
    print_status_plain, remove_if_exists, render_launch_agent_plist, resolve_bridge_config,
    stringify_metadata_map, uptime_from_started_at,
};
use runtime::{
    matches_running_config, run_bridge_server, spawn_codex_monitor, spawn_codex_process,
};
use server::BridgeServer;
use types::{
    CODEX_READY_POLL_INTERVAL, CODEX_READY_PROBE_TIMEOUT, CODEX_READY_TIMEOUT,
    CODEX_READY_WARN_AFTER, DEFAULT_BRIDGE_SOCKET_NAME, DETACHED_START_POLL_INTERVAL,
    DETACHED_START_TIMEOUT, FALLBACK_BRIDGE_SOCKET_PREFIX, FALLBACK_BRIDGE_SOCKET_SUFFIX,
    PersistedBridgeConfig, STOP_GRACE_PERIOD, STOP_POLL_INTERVAL, UNIX_SOCKET_PATH_LIMIT,
    WATCH_DEBOUNCE, status_report_from_state,
};

pub(crate) use bridge_state::acquire_bridge_lock_exclusive;
pub use bridge_state::{
    LivenessMode, bridge_config_path, bridge_socket_path, bridge_state_path,
    codex_websocket_endpoint, ensure_host_context, host_bridge_manifest, load_running_bridge_state,
    pid_alive, read_bridge_state, running_codex_capability, status_report,
};
pub use client::BridgeClient;
pub use commands::BridgeCommand;
pub use control::{reconfigure_bridge, spawn_manifest_watcher, stop_bridge};
pub(crate) use runtime::probe_codex_readiness;
pub use types::{
    AgentTuiStartSpec, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX,
    BRIDGE_LAUNCH_AGENT_LABEL, BridgeCapability, BridgeConfigArgs, BridgeInstallLaunchAgentArgs,
    BridgeReconfigureArgs, BridgeRemoveLaunchAgentArgs, BridgeStartArgs, BridgeState,
    BridgeStatusArgs, BridgeStatusReport, BridgeStopArgs, CODEX_BRIDGE_PORT_ENV,
    DEFAULT_CODEX_BRIDGE_PORT, compiled_capabilities,
};

#[cfg(test)]
mod tests;

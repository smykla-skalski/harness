use std::env;
use std::path::PathBuf;

/// macOS app-group identifier shared by Harness Monitor and the MCP server.
pub const DEFAULT_APP_GROUP: &str = "Q498EB36N4.io.harnessmonitor";

/// Filename of the Unix socket inside the app-group container.
pub const SOCKET_FILENAME: &str = "harness-monitor-mcp.sock";

/// Environment variable that overrides the default socket path. Useful for
/// running the Harness Monitor app unsandboxed during development.
pub const SOCKET_OVERRIDE_ENV: &str = "HARNESS_MONITOR_MCP_SOCKET";

/// Resolve the socket path the MCP server connects to. Falls back to the
/// default location under the current user's group container if no
/// environment override is set.
#[must_use]
pub fn default_socket_path() -> PathBuf {
    if let Some(override_path) = env::var_os(SOCKET_OVERRIDE_ENV)
        && !override_path.is_empty()
    {
        return PathBuf::from(override_path);
    }
    let mut path = dirs_home().unwrap_or_else(|| PathBuf::from("/tmp"));
    path.push("Library");
    path.push("Group Containers");
    path.push(DEFAULT_APP_GROUP);
    path.push(SOCKET_FILENAME);
    path
}

fn dirs_home() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

use std::env;
use std::path::PathBuf;

/// macOS app-group identifier shared by Harness Monitor and the MCP server.
pub const DEFAULT_APP_GROUP: &str = "Q498EB36N4.io.harnessmonitor";

/// Filename of the Unix socket inside the app-group container.
/// Keep short - Unix domain sockets have a 104-byte path limit on macOS.
pub const SOCKET_FILENAME: &str = "mcp.sock";

/// Filename of the registry capability token inside the app-group container.
pub const TOKEN_FILENAME: &str = "mcp.token";

/// Environment variable that overrides the default socket path. Useful for
/// running the Harness Monitor app unsandboxed during development.
pub const SOCKET_OVERRIDE_ENV: &str = "HARNESS_MONITOR_MCP_SOCKET";

/// Environment variable that supplies the registry capability token directly.
pub const TOKEN_OVERRIDE_ENV: &str = "HARNESS_MONITOR_MCP_TOKEN";

/// Environment variable that overrides the registry capability token file path.
pub const TOKEN_FILE_OVERRIDE_ENV: &str = "HARNESS_MONITOR_MCP_TOKEN_FILE";

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

/// Resolve the default registry capability token path. The token sits next to
/// the socket so socket overrides in development can use an isolated token too.
#[must_use]
pub fn default_token_path() -> PathBuf {
    if let Some(override_path) = env::var_os(TOKEN_FILE_OVERRIDE_ENV)
        && !override_path.is_empty()
    {
        return PathBuf::from(override_path);
    }
    let mut path = default_socket_path();
    path.set_file_name(TOKEN_FILENAME);
    path
}

fn dirs_home() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

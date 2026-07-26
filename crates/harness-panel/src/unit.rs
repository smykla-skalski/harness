//! Rendering the panel's systemd unit.
//!
//! The unit is printed rather than installed, so an operator reviews it before
//! it lands. Its shape follows the remote daemon's unit: a dynamic user, a
//! state directory, and no capability to bind a privileged port, because the
//! panel is reached through the daemon rather than from the network.
//!
//! `systemd-analyze security` scored the result 1.1 when this was written, the
//! best a service that serves HTTP and calls GitHub can reach. What it still
//! counts against the unit is inherent to that job: it has host network access,
//! may allocate Internet and local sockets, and pins no IP allow list, because
//! GitHub's address ranges rotate and a stale list would take sign-in down
//! silently. `char-rtc:r` in the device ACL is what `ProtectClock=` itself
//! adds, and dropping `ProtectClock=` scores worse.
//!
//! [`tests`] keeps the exposure at or below 1.5 rather than pinning it to the
//! measured figure, so a systemd release that reweights a check does not fail
//! the build; it is a guard against a directive being dropped, not a record of
//! the score. It measures nothing where `systemd-analyze` is absent, which is
//! macOS and any Linux host without systemd.

use std::net::SocketAddr;
use std::path::Path;

use crate::config::{PanelArgs, ValidatedPanelArgs, validate_listen};
use crate::error::PanelError;
use crate::serve::SYSTEMD_SOCKET_NAME;

/// Where private credentials are exposed inside the unit. `LoadCredential`
/// keeps the copies in a protected directory and grants the dynamic user read
/// access without exposing the root-only source files.
const GITHUB_CREDENTIAL_NAME: &str = "github-client-secret";
const COMPANION_AUTH_CREDENTIAL_NAME: &str = "companion-auth-token";

const SERVICE_UNIT_SUFFIX: &str = ".service";
const SOCKET_UNIT_SUFFIX: &str = ".socket";

/// systemd's own ceiling on a unit name, less the longer suffix added here.
const MAX_UNIT_NAME_CHARS: usize = 255 - SERVICE_UNIT_SUFFIX.len();

/// Render a unit that starts `binary_path` with these flags.
///
/// # Errors
/// Returns [`PanelError::Config`] when the unit name is not one systemd would
/// read back as a single name, a required host path is not absolute, a flag
/// would not survive systemd's `ExecStart` parsing, or the mount point is not a
/// usable subtree.
pub fn render_unit(unit: &str, binary_path: &Path, args: &PanelArgs) -> Result<String, PanelError> {
    let validated = args.validate_runtime()?;
    validate_unit_listen(args.listen)?;
    validate_unit_name(unit)?;
    require_absolute_path("the panel binary path", binary_path)?;
    require_absolute_path(
        "the github client secret source path",
        &args.github_client_secret_file,
    )?;
    require_absolute_path(
        "the companion auth token source path",
        &args.companion_auth_token_file,
    )?;
    let exec_start = render_exec_start(&serve_command(unit, binary_path, args, &validated)?);
    // The secret path is the one operator value that never reaches `ExecStart`,
    // because the command points at the credential systemd re-exposes instead.
    // It still lands in a directive, so it needs the same refusal and the same
    // specifier escaping.
    let secret_source = render_directive_path(
        "the github client secret path",
        &args.github_client_secret_file,
    )?;
    let companion_auth_source = render_directive_path(
        "the companion auth token path",
        &args.companion_auth_token_file,
    )?;
    let socket_unit = format!("{unit}{SOCKET_UNIT_SUFFIX}");
    Ok(format!(
        "[Unit]\n\
         Description=Harness panel\n\
         Requires={socket_unit}\n\
         After=network-online.target {socket_unit}\n\
         Wants=network-online.target\n\
         \n\
         [Service]\n\
         Type=exec\n\
         NonBlocking=true\n\
         Sockets={socket_unit}\n\
         ExecStart={exec_start}\n\
         Restart=on-failure\n\
         RestartSec=5s\n\
         LoadCredential={GITHUB_CREDENTIAL_NAME}:{secret_source}\n\
         LoadCredential={COMPANION_AUTH_CREDENTIAL_NAME}:{companion_auth_source}\n\
         Environment=RUST_LOG=harness_panel=info\n\
         Environment=HARNESS_PANEL_REQUIRE_SOCKET_ACTIVATION=1\n\
         NoNewPrivileges=true\n\
         DynamicUser=yes\n\
         PrivateTmp=true\n\
         PrivateDevices=true\n\
         PrivateMounts=true\n\
         PrivateUsers=true\n\
         ProtectSystem=strict\n\
         ProtectHome=true\n\
         ProtectClock=true\n\
         ProtectControlGroups=true\n\
         ProtectHostname=true\n\
         ProtectKernelLogs=true\n\
         ProtectKernelModules=true\n\
         ProtectKernelTunables=true\n\
         ProtectProc=invisible\n\
         ProcSubset=pid\n\
         LockPersonality=true\n\
         MemoryDenyWriteExecute=true\n\
         RestrictNamespaces=true\n\
         RestrictRealtime=true\n\
         RestrictSUIDSGID=true\n\
         RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n\
         SystemCallArchitectures=native\n\
         SystemCallFilter=@system-service\n\
         SystemCallFilter=~@privileged @resources\n\
         SystemCallErrorNumber=EPERM\n\
         CapabilityBoundingSet=\n\
         StateDirectory={unit}\n\
         StateDirectoryMode=0700\n\
         UMask=0077\n\
         \n\
         [Install]\n\
         WantedBy=multi-user.target\n"
    ))
}

/// Render the socket unit that owns the panel's loopback listener.
///
/// # Errors
/// Returns [`PanelError::Config`] when the unit name is unusable or `listen`
/// is not a loopback address.
pub fn render_socket_unit(unit: &str, listen: SocketAddr) -> Result<String, PanelError> {
    validate_unit_name(unit)?;
    validate_unit_listen(listen)?;
    let service_unit = format!("{unit}{SERVICE_UNIT_SUFFIX}");
    Ok(format!(
        "[Unit]\n\
         Description=Harness panel socket\n\
         \n\
         [Socket]\n\
         ListenStream={listen}\n\
         Accept=no\n\
         FileDescriptorName={SYSTEMD_SOCKET_NAME}\n\
         ReusePort=false\n\
         Service={service_unit}\n\
         \n\
         [Install]\n\
         WantedBy=sockets.target\n"
    ))
}

fn validate_unit_listen(listen: SocketAddr) -> Result<(), PanelError> {
    validate_listen(listen)?;
    if listen.port() == 0 {
        return Err(PanelError::config(
            "--listen must use a non-zero port in a systemd deployment",
        ));
    }
    Ok(())
}

fn require_absolute_path(label: &str, path: &Path) -> Result<(), PanelError> {
    if !path.is_absolute() {
        return Err(PanelError::config(format!("{label} must be absolute")));
    }
    Ok(())
}

/// Refuse a value that would not survive the unit file's line structure.
///
/// A newline ends the directive it sits in and lets the rest of the value
/// become a directive of its own, so every operator-supplied value reaches the
/// rendered unit through here rather than only the ones on `ExecStart`.
fn refuse_control_characters(label: &str, value: &str) -> Result<(), PanelError> {
    if value.chars().any(char::is_control) {
        return Err(PanelError::config(format!(
            "{label} contains control characters: {value:?}"
        )));
    }
    Ok(())
}

/// Render a host path inside a systemd directive without changing its parse.
fn render_directive_path(label: &str, path: &Path) -> Result<String, PanelError> {
    let value = path
        .to_str()
        .ok_or_else(|| PanelError::config(format!("{label} must be valid UTF-8")))?;
    if value.chars().any(|character| {
        character.is_whitespace()
            || character.is_control()
            || matches!(character, '\\' | '"' | '\'')
    }) {
        return Err(PanelError::config(format!(
            "{label} contains whitespace, control characters, quotes, or backslashes that are \
             unsafe in a systemd directive"
        )));
    }
    // systemd expands `%` specifiers in directive values. `%%` preserves a
    // literal percent from the operator's path.
    Ok(value.replace('%', "%%"))
}

/// Refuse a unit name that would not survive the two places it is used.
///
/// [`refuse_control_characters`] already covers the newline that would end a
/// directive. This is the rest: the name lands in `StateDirectory=`, which
/// systemd reads as a space-separated list, and inside `%S/{unit}`, which the
/// renderer emits as a bare `ExecStart` word so the specifier survives. A space
/// therefore silently becomes two state directories and two arguments, and a
/// separator or `..` points the state directory outside the tree systemd just
/// created for it. The rule is stricter than a full unit name read back from
/// `systemctl`, because this is a name the panel composes paths from.
fn validate_unit_name(unit: &str) -> Result<(), PanelError> {
    if unit.is_empty() {
        return Err(PanelError::config("--unit must not be blank"));
    }
    if unit.chars().count() > MAX_UNIT_NAME_CHARS {
        return Err(PanelError::config(format!(
            "--unit must be at most {MAX_UNIT_NAME_CHARS} characters"
        )));
    }
    if !unit
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.'))
    {
        return Err(PanelError::config(format!(
            "--unit must contain only ASCII letters, digits, '-', '_', and '.', got {unit:?}"
        )));
    }
    if unit.starts_with('.') || unit.contains("..") {
        return Err(PanelError::config(format!(
            "--unit must not start with '.' or contain '..', got {unit:?}"
        )));
    }
    if unit.ends_with(SERVICE_UNIT_SUFFIX) || unit.ends_with(SOCKET_UNIT_SUFFIX) {
        return Err(PanelError::config(format!(
            "--unit is a stem and must not end in {SERVICE_UNIT_SUFFIX} or {SOCKET_UNIT_SUFFIX}"
        )));
    }
    Ok(())
}

/// One `ExecStart` word.
///
/// The distinction matters because `%` introduces a systemd specifier. A path
/// the panel builds from `%S` or `%d` means that literally, while anything an
/// operator typed does not, and escaping both the same way would break one of
/// them.
enum ExecArgument {
    /// Emitted exactly as written, specifiers and all.
    Specifier(String),
    /// Escaped so systemd sees the value the operator typed.
    Value(String),
}

fn serve_command(
    unit: &str,
    binary_path: &Path,
    args: &PanelArgs,
    validated: &ValidatedPanelArgs,
) -> Result<Vec<ExecArgument>, PanelError> {
    let command = vec![
        ExecArgument::Value(binary_path.display().to_string()),
        ExecArgument::Value("serve".to_owned()),
        ExecArgument::Value("--listen".to_owned()),
        ExecArgument::Value(args.listen.to_string()),
        ExecArgument::Value("--public-origin".to_owned()),
        ExecArgument::Value(args.public_origin.clone()),
        ExecArgument::Value("--base-path".to_owned()),
        // Rendered back as a path rather than as the normalized value: the
        // origin root normalizes to nothing, and `--base-path ""` is a flag the
        // panel would refuse on the next start. `/` round-trips to the same
        // configuration.
        ExecArgument::Value(if validated.base_path.is_empty() {
            "/".to_owned()
        } else {
            validated.base_path.clone()
        }),
        ExecArgument::Value("--state-dir".to_owned()),
        // %S is systemd's state directory root, so the panel writes where
        // StateDirectory= already granted it access rather than somewhere the
        // sandbox would refuse.
        ExecArgument::Specifier(format!("%S/{unit}")),
        ExecArgument::Value("--companion-auth-token-file".to_owned()),
        // %d is the credentials directory LoadCredential= populated.
        ExecArgument::Specifier(format!("%d/{COMPANION_AUTH_CREDENTIAL_NAME}")),
        ExecArgument::Value("--github-client-id".to_owned()),
        ExecArgument::Value(args.github_client_id.clone()),
        ExecArgument::Value("--github-authorize-url".to_owned()),
        ExecArgument::Value(args.github_authorize_url.clone()),
        ExecArgument::Value("--github-token-url".to_owned()),
        ExecArgument::Value(args.github_token_url.clone()),
        ExecArgument::Value("--github-api-url".to_owned()),
        ExecArgument::Value(args.github_api_url.clone()),
        ExecArgument::Value("--github-client-secret-file".to_owned()),
        // %d is the credentials directory LoadCredential= populated.
        ExecArgument::Specifier(format!("%d/{GITHUB_CREDENTIAL_NAME}")),
        ExecArgument::Value("--owner-login".to_owned()),
        ExecArgument::Value(args.owner_login.clone()),
        ExecArgument::Value("--session-ttl-hours".to_owned()),
        ExecArgument::Value(args.session_ttl_hours.to_string()),
        // Every flag `serve` requires has to appear here. A required flag added
        // to the arguments and not to this list renders a unit that clap
        // rejects at once, which under Restart=on-failure is a boot loop rather
        // than a visible error. `every_required_serve_flag_is_rendered` holds
        // the two lists together.
        ExecArgument::Value("--daemon-endpoint".to_owned()),
        ExecArgument::Value(args.daemon_endpoint.clone()),
        ExecArgument::Value("--daemon-spki-pin".to_owned()),
        ExecArgument::Value(args.daemon_spki_pin.clone()),
        ExecArgument::Value("--pair-link-role".to_owned()),
        ExecArgument::Value(args.pair_link_role.clone()),
        ExecArgument::Value("--pair-link-ttl-seconds".to_owned()),
        ExecArgument::Value(args.pair_link_ttl_seconds.to_string()),
    ];

    for argument in &command {
        let value = match argument {
            ExecArgument::Specifier(value) | ExecArgument::Value(value) => value,
        };
        refuse_control_characters("a systemd ExecStart argument", value)?;
    }
    Ok(command)
}

fn render_exec_start(command: &[ExecArgument]) -> String {
    command
        .iter()
        .map(|argument| match argument {
            ExecArgument::Specifier(value) => value.clone(),
            ExecArgument::Value(value) => render_exec_value(value),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Quote an operator-supplied argument the way systemd parses `ExecStart`.
///
/// `%` and `$` both have to be doubled, and neither may take the bare path.
/// systemd expands variables after it has split the line into words and thrown
/// the quotes away, so quoting alone does not stop the expansion: a bare `$FOO`
/// word whose variable is unset expands to *no* argument at all rather than an
/// empty one, silently deleting a flag and shifting everything after it.
fn render_exec_value(argument: &str) -> String {
    if !argument.is_empty() && argument.chars().all(is_bare_exec_char) {
        return argument.to_owned();
    }
    let mut quoted = String::with_capacity(argument.len() + 2);
    quoted.push('"');
    for character in argument.chars() {
        match character {
            '"' | '\\' => {
                quoted.push('\\');
                quoted.push(character);
            }
            '$' => quoted.push_str("$$"),
            '%' => quoted.push_str("%%"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

fn is_bare_exec_char(character: char) -> bool {
    !character.is_whitespace() && !matches!(character, '"' | '$' | '%' | '\'' | '\\')
}

#[cfg(test)]
mod tests;

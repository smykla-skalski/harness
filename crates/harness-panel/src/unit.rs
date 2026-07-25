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

use std::path::Path;

use crate::config::{PanelArgs, normalize_base_path};
use crate::error::PanelError;

/// Where the client secret is exposed inside the unit. `LoadCredential` copies
/// it in as mode 0400 owned by the dynamic user, which is what lets the source
/// file stay root-only and still satisfy the panel's permission check.
const CREDENTIAL_NAME: &str = "github-client-secret";

/// systemd's own ceiling on a unit name.
const MAX_UNIT_NAME_CHARS: usize = 255;

/// Render a unit that starts `binary_path` with these flags.
///
/// # Errors
/// Returns [`PanelError::Config`] when the unit name is not one systemd would
/// read back as a single name, when a flag would not survive systemd's
/// `ExecStart` parsing, or when the mount point is not a usable subtree.
pub fn render_unit(unit: &str, binary_path: &Path, args: &PanelArgs) -> Result<String, PanelError> {
    validate_unit_name(unit)?;
    let exec_start = render_exec_start(&serve_command(unit, binary_path, args)?);
    // The secret path is the one operator value that never reaches `ExecStart`,
    // because the command points at the credential systemd re-exposes instead.
    // It still lands in a directive, so it needs the same refusal and the same
    // specifier escaping.
    let secret_source = args.github_client_secret_file.display().to_string();
    refuse_control_characters("the github client secret path", &secret_source)?;
    let secret_source = escape_directive_value(&secret_source);
    Ok(format!(
        "[Unit]\n\
         Description=Harness panel\n\
         After=network-online.target\n\
         Wants=network-online.target\n\
         \n\
         [Service]\n\
         Type=exec\n\
         ExecStart={exec_start}\n\
         Restart=on-failure\n\
         RestartSec=5s\n\
         LoadCredential={CREDENTIAL_NAME}:{secret_source}\n\
         Environment=RUST_LOG=harness_panel=info\n\
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

/// Escape a value the panel writes into a directive rather than `ExecStart`.
///
/// systemd expands `%` specifiers in directive values too, not only on the
/// command line, so a path an operator typed with a `%` in it would be read as
/// a specifier and resolve to something else entirely. `%%` is how systemd
/// spells a literal `%`. Quoting is not involved here: unlike `ExecStart`,
/// a directive value is taken whole, so escaping is the only thing needed.
fn escape_directive_value(value: &str) -> String {
    value.replace('%', "%%")
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
) -> Result<Vec<ExecArgument>, PanelError> {
    let base_path = normalize_base_path(&args.base_path)?;
    let command = vec![
        ExecArgument::Value(binary_path.display().to_string()),
        ExecArgument::Value("serve".to_owned()),
        ExecArgument::Value("--listen".to_owned()),
        ExecArgument::Value(args.listen.to_string()),
        ExecArgument::Value("--public-origin".to_owned()),
        ExecArgument::Value(args.public_origin.clone()),
        ExecArgument::Value("--base-path".to_owned()),
        ExecArgument::Value(base_path),
        ExecArgument::Value("--state-dir".to_owned()),
        // %S is systemd's state directory root, so the panel writes where
        // StateDirectory= already granted it access rather than somewhere the
        // sandbox would refuse.
        ExecArgument::Specifier(format!("%S/{unit}")),
        ExecArgument::Value("--github-client-id".to_owned()),
        ExecArgument::Value(args.github_client_id.clone()),
        ExecArgument::Value("--github-client-secret-file".to_owned()),
        // %d is the credentials directory LoadCredential= populated.
        ExecArgument::Specifier(format!("%d/{CREDENTIAL_NAME}")),
        ExecArgument::Value("--owner-login".to_owned()),
        ExecArgument::Value(args.owner_login.clone()),
        ExecArgument::Value("--session-ttl-hours".to_owned()),
        ExecArgument::Value(args.session_ttl_hours.to_string()),
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

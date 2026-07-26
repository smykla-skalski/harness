//! What happens to a value an operator typed, before it reaches systemd.
//!
//! `ExecStart` and directive values expand specifiers and variables, so a `%`
//! or a `$` in an operator's path is not the character they meant, and a
//! newline ends the directive and starts one the panel never wrote.

use std::path::{Path, PathBuf};

use super::super::render_unit;
use super::{args, rendered};

/// A `%` an operator typed is not a systemd specifier, and leaving it bare
/// would have systemd substitute something else into the command line.
#[test]
fn an_operator_supplied_percent_is_escaped() {
    let mut args = args();
    args.owner_login = "ada%h".to_owned();

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(unit.contains("--owner-login \"ada%%h\""), "{unit}");
}

/// systemd expands variables after it has split the line and dropped the
/// quotes, so a bare `$FOO` word whose variable is unset expands to no argument
/// at all. Left unescaped, `--owner-login $UNSET` would drop the value and hand
/// clap the next flag as the login.
#[test]
fn an_operator_supplied_dollar_is_escaped() {
    let mut args = args();
    args.owner_login = "$UNSET".to_owned();

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(unit.contains("--owner-login \"$$UNSET\""), "{unit}");
    assert!(!unit.contains("--owner-login $UNSET"), "{unit}");
}

/// The secret path is the one operator value that never reaches `ExecStart`, so
/// nothing on the command path would have refused a newline in it and the rest
/// of the value would become its own unit directive.
#[test]
fn a_control_character_in_the_secret_path_is_refused() {
    let mut args = args();
    args.github_client_secret_file =
        PathBuf::from("/etc/harness-panel/secret\nExecStartPost=/bin/sh -c curl");

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("a newline in the secret path must be refused");

    assert!(error.to_string().contains("control characters"), "{error}");
}

#[test]
fn a_control_character_in_the_companion_auth_path_is_refused() {
    let mut args = args();
    args.companion_auth_token_file =
        PathBuf::from("/etc/harness-panel/token\nExecStartPost=/bin/sh -c curl");

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("a newline in the token path must be refused");

    assert!(error.to_string().contains("control characters"), "{error}");
}

/// `LoadCredential=` expands specifiers just as `ExecStart` does, so a `%` an
/// operator typed into the secret path would resolve to something else and
/// systemd would look for the credential somewhere they never named.
#[test]
fn a_percent_in_the_secret_path_is_escaped() {
    let mut args = args();
    args.github_client_secret_file = PathBuf::from("/etc/harness-panel/100%secret");

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(
        unit.contains("LoadCredential=github-client-secret:/etc/harness-panel/100%%secret"),
        "{unit}"
    );
}

#[test]
fn a_percent_in_the_companion_auth_path_is_escaped() {
    let mut args = args();
    args.companion_auth_token_file = PathBuf::from("/etc/harness-panel/100%token");

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(
        unit.contains("LoadCredential=companion-auth-token:/etc/harness-panel/100%%token"),
        "{unit}"
    );
}

/// The two specifiers the panel builds deliberately mean what they say, so
/// escaping them alongside operator input would break the paths.
#[test]
fn the_panels_own_specifiers_stay_bare() {
    let unit = rendered();

    assert!(!unit.contains("%%S/"), "{unit}");
    assert!(!unit.contains("%%d/"), "{unit}");
}


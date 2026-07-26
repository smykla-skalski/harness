use std::path::{Path, PathBuf};

use super::render_unit;
use crate::config::{
    DEFAULT_GITHUB_API_URL, DEFAULT_GITHUB_AUTHORIZE_URL, DEFAULT_GITHUB_TOKEN_URL, PanelArgs,
};

mod credential_paths;
mod escaping;
mod socket;

fn args() -> PanelArgs {
    PanelArgs {
        listen: "127.0.0.1:8787".parse().expect("listen address"),
        public_origin: "https://harness.example.com".to_owned(),
        base_path: "/panel/".to_owned(),
        state_dir: PathBuf::from("/var/lib/harness-panel"),
        companion_auth_token_file: PathBuf::from("/etc/harness-panel/companion-auth-token"),
        github_client_id: "Iv1.abc".to_owned(),
        github_client_secret_file: PathBuf::from("/etc/harness-panel/github-client-secret"),
        owner_login: "ada".to_owned(),
        github_authorize_url: DEFAULT_GITHUB_AUTHORIZE_URL.to_owned(),
        github_token_url: DEFAULT_GITHUB_TOKEN_URL.to_owned(),
        github_api_url: DEFAULT_GITHUB_API_URL.to_owned(),
        session_ttl_hours: 12,
        daemon_endpoint: "https://harness.example.com".to_owned(),
        daemon_spki_pin: "sha256/AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=".to_owned(),
        pair_link_role: "operator".to_owned(),
        pair_link_ttl_seconds: 600,
    }
}

fn rendered() -> String {
    render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args(),
    )
    .expect("a renderable unit")
}

#[test]
fn the_unit_starts_the_panel_with_the_configured_flags() {
    let unit = rendered();

    assert!(
        unit.contains(
            "ExecStart=/usr/local/bin/harness-panel serve --listen 127.0.0.1:8787 \
             --public-origin https://harness.example.com --base-path /panel"
        ),
        "{unit}"
    );
    assert!(unit.contains("--owner-login ada"), "{unit}");
    assert!(unit.contains("--session-ttl-hours 12"), "{unit}");
}

#[test]
fn a_relative_binary_path_is_refused() {
    let error = render_unit("harness-panel", Path::new("harness-panel"), &args())
        .expect_err("the service binary path must be absolute");
    let message = error.to_string();

    assert!(message.contains("binary path"), "{message}");
    assert!(message.contains("must be absolute"), "{message}");
}

#[test]
fn a_relative_client_secret_source_path_is_refused() {
    let mut args = args();
    args.github_client_secret_file = PathBuf::from("github-client-secret");

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("the credential source path must be absolute");
    let message = error.to_string();

    assert!(message.contains("client secret source path"), "{message}");
    assert!(message.contains("must be absolute"), "{message}");
}

#[test]
fn a_relative_companion_auth_source_path_is_refused() {
    let mut args = args();
    args.companion_auth_token_file = PathBuf::from("companion-auth-token");

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("the credential source path must be absolute");
    let message = error.to_string();

    assert!(
        message.contains("companion auth token source path"),
        "{message}"
    );
    assert!(message.contains("must be absolute"), "{message}");
}

#[test]
fn the_unit_preserves_github_enterprise_endpoints() {
    let mut args = args();
    args.github_authorize_url = "https://ghe.example.com/login/oauth/authorize".to_owned();
    args.github_token_url = "https://ghe.example.com/login/oauth/access_token".to_owned();
    args.github_api_url = "https://ghe.example.com/api/v3".to_owned();

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(
        unit.contains("--github-authorize-url https://ghe.example.com/login/oauth/authorize"),
        "{unit}"
    );
    assert!(
        unit.contains("--github-token-url https://ghe.example.com/login/oauth/access_token"),
        "{unit}"
    );
    assert!(
        unit.contains("--github-api-url https://ghe.example.com/api/v3"),
        "{unit}"
    );
}

#[test]
fn a_rejected_endpoint_never_exposes_its_value() {
    let mut args = args();
    args.github_api_url = "https://ghe.example.com/api/token=secret\n".to_owned();

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("a control character in an endpoint must be refused");
    let message = error.to_string();

    assert!(message.contains("--github-api-url"), "{message}");
    assert!(message.contains("control characters"), "{message}");
    assert!(!message.contains("secret"), "{message}");
}

/// The rendered flags are what the panel actually runs with, so a mount point
/// the operator typed with a trailing slash has to be normalised here too.
#[test]
fn the_mount_point_is_normalised_into_the_unit() {
    assert!(rendered().contains("--base-path /panel "), "{}", rendered());
}

/// `ProtectSystem=strict` makes the filesystem read-only apart from
/// `StateDirectory`, so the panel has to be pointed at that directory rather
/// than at whatever path the operator typed.
#[test]
fn the_state_directory_is_the_one_systemd_granted() {
    let unit = rendered();

    assert!(unit.contains("--state-dir %S/harness-panel"), "{unit}");
    assert!(unit.contains("StateDirectory=harness-panel"), "{unit}");
    assert!(unit.contains("StateDirectoryMode=0700"), "{unit}");
}

/// `DynamicUser=yes` means the service account does not exist until start, so a
/// root-only secret file can only reach it through `LoadCredential`, which
/// re-exposes it as mode 0400 owned by that user.
#[test]
fn the_client_secret_arrives_as_a_credential() {
    let unit = rendered();

    assert!(
        unit.contains(
            "LoadCredential=github-client-secret:/etc/harness-panel/github-client-secret"
        ),
        "{unit}"
    );
    assert!(
        unit.contains("--github-client-secret-file %d/github-client-secret"),
        "{unit}"
    );
}

#[test]
fn the_companion_auth_token_arrives_as_a_credential() {
    let unit = rendered();

    assert!(
        unit.contains(
            "LoadCredential=companion-auth-token:/etc/harness-panel/companion-auth-token"
        ),
        "{unit}"
    );
    assert!(
        unit.contains("--companion-auth-token-file %d/companion-auth-token"),
        "{unit}"
    );
}

/// The panel is reached through the daemon, never from the network, so it never
/// needs to bind a privileged port.
#[test]
fn the_unit_grants_no_capabilities() {
    let unit = rendered();

    assert!(unit.contains("CapabilityBoundingSet=\n"), "{unit}");
    assert!(!unit.contains("CAP_NET_BIND_SERVICE"), "{unit}");
    assert!(unit.contains("DynamicUser=yes"), "{unit}");
    assert!(unit.contains("NoNewPrivileges=true"), "{unit}");
    assert!(unit.contains("ProtectSystem=strict"), "{unit}");
}

/// The unit is what actually starts the panel, so every flag `serve` requires
/// has to appear in it. Reading the requirement off `PanelArgs` rather than
/// listing it here is what keeps the two from drifting: a required flag added
/// to the arguments and not to the renderer produced a unit that clap rejected
/// at once, which under `Restart=on-failure` is a boot loop rather than a
/// visible error.
#[test]
fn every_required_serve_flag_is_rendered() {
    // `PanelArgs` derives `Args`, not `Parser`, so the command has to be built
    // by augmenting an empty one.
    use clap::{Args, Command};

    let command = PanelArgs::augment_args(Command::new("serve"));
    let unit = rendered();
    // Whole words off the `ExecStart` line, not a substring of the whole unit.
    // A substring search answers yes to a flag that only appears inside a
    // value, and no to one rendered last with no space after it.
    let exec_start = unit
        .lines()
        .find(|line| line.starts_with("ExecStart="))
        .expect("a rendered ExecStart");
    let words: Vec<&str> = exec_start.split_whitespace().collect();
    let mut missing = Vec::new();
    for argument in command.get_arguments() {
        if !argument.is_required_set() {
            continue;
        }
        let Some(long) = argument.get_long() else {
            continue;
        };
        if !words.contains(&format!("--{long}").as_str()) {
            missing.push(long.to_owned());
        }
    }

    assert!(
        missing.is_empty(),
        "the rendered unit omits required serve flags: {missing:?}"
    );
}

/// `StateDirectory=` is a space-separated list and `%S/{unit}` is emitted as a
/// bare `ExecStart` word, so a name with a space quietly becomes two of each.
/// A separator or `..` would point the state directory out of the tree systemd
/// created for it.
#[test]
fn a_unit_name_that_would_not_survive_systemd_is_refused() {
    for unit in [
        "harness panel",
        "../../etc/systemd/system/evil",
        "harness/panel",
        ".hidden",
        "harness..panel",
        "harness\npanel",
        "harness%panel",
        "harness$panel",
        "harness-panel.service",
        "harness-panel.socket",
        "",
    ] {
        assert!(
            render_unit(unit, Path::new("/usr/local/bin/harness-panel"), &args()).is_err(),
            "{unit:?} should be refused"
        );
    }
}

#[test]
fn an_ordinary_unit_name_is_accepted() {
    for unit in ["harness-panel", "harness_panel", "panel.v2", "p1"] {
        assert!(
            render_unit(unit, Path::new("/usr/local/bin/harness-panel"), &args()).is_ok(),
            "{unit:?} should be accepted"
        );
    }
}

#[test]
fn a_value_with_whitespace_is_quoted() {
    let mut args = args();
    args.owner_login = "ada lovelace".to_owned();

    let unit = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect("a renderable unit");

    assert!(unit.contains("--owner-login \"ada lovelace\""), "{unit}");
}

/// A newline would end the `ExecStart` line and let the rest of the value
/// become its own unit directive.
#[test]
fn a_control_character_is_refused_rather_than_quoted() {
    let mut args = args();
    args.public_origin = "https://harness.example.com\nExecStartPost=/bin/sh".to_owned();

    let error = render_unit(
        "harness-panel",
        Path::new("/usr/local/bin/harness-panel"),
        &args,
    )
    .expect_err("a newline must be refused");

    assert!(error.to_string().contains("control characters"), "{error}");
}

#[test]
fn every_runtime_flag_is_validated_before_rendering() {
    type InvalidCase = (&'static str, fn(&mut PanelArgs));
    let cases: &[InvalidCase] = &[
        ("--listen", |args| {
            args.listen = "0.0.0.0:8787".parse().unwrap();
        }),
        ("--public-origin", |args| {
            args.public_origin = "http://example.com".into();
        }),
        ("--base-path", |args| args.base_path = "/".into()),
        ("--github-client-id", |args| {
            args.github_client_id = " ".into();
        }),
        ("--owner-login", |args| args.owner_login = " ".into()),
        ("--github-authorize-url", |args| {
            args.github_authorize_url = "ftp://example.com".into();
        }),
        ("--github-token-url", |args| {
            args.github_token_url = "ftp://example.com".into();
        }),
        ("--github-api-url", |args| {
            args.github_api_url = "ftp://example.com".into();
        }),
        ("--session-ttl-hours", |args| args.session_ttl_hours = 0),
        ("--session-ttl-hours", |args| {
            args.session_ttl_hours = u32::MAX;
        }),
    ];

    for &(flag, make_invalid) in cases {
        let mut args = args();
        make_invalid(&mut args);
        let error = render_unit("harness-panel", Path::new("/usr/bin/harness-panel"), &args)
            .expect_err("invalid runtime configuration must not render");
        assert!(error.to_string().contains(flag), "{flag}: {error}");
    }
}

#[test]
fn rendering_does_not_read_private_credential_files() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args();
    args.github_client_secret_file = directory.path().join("missing-client-secret");
    args.companion_auth_token_file = directory.path().join("missing-companion-token");

    render_unit("harness-panel", Path::new("/usr/bin/harness-panel"), &args)
        .expect("rendering only names credential source files");
}

/// The hardening is only worth what systemd actually scores it at, and a
/// directive dropped in a later edit would otherwise go unnoticed.
///
/// Skipped where the tool does not exist: macOS, and Linux hosts without
/// systemd. Every other assertion in this file still covers the directives.
#[cfg(target_os = "linux")]
#[test]
fn systemd_scores_the_unit_in_its_safest_reachable_band() {
    use std::fs;
    use std::process::Command;

    let directory = tempfile::tempdir().expect("temp dir");
    let path = directory.path().join("harness-panel.service");
    fs::write(&path, rendered()).expect("writing the unit");

    let Ok(output) = Command::new("systemd-analyze")
        .args(["security", "--offline=true"])
        .arg(&path)
        .output()
    else {
        return;
    };
    assert!(
        output.status.success(),
        "systemd-analyze failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let report = String::from_utf8_lossy(&output.stdout);
    let exposure = report
        .lines()
        .find_map(|line| line.split("exposure level for").nth(1))
        .and_then(|tail| tail.split_whitespace().nth(1).map(str::to_owned))
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or_else(|| panic!("no exposure level in:\n{report}"));

    assert!(
        exposure <= 1.5,
        "exposure rose to {exposure}; a hardening directive was probably dropped:\n{report}"
    );
}

#[test]
fn an_unusable_mount_point_is_refused() {
    let mut args = args();
    args.base_path = "/".to_owned();

    assert!(
        render_unit(
            "harness-panel",
            Path::new("/usr/local/bin/harness-panel"),
            &args
        )
        .is_err()
    );
}

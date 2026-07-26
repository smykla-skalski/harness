use std::path::{Path, PathBuf};

use super::args;
use crate::unit::render_unit;

#[test]
fn directive_syntax_in_credential_paths_is_refused() {
    for path in [
        "/etc/harness-panel/token\\",
        "/etc/harness-panel/token\"quoted",
        "/etc/harness-panel/token'quoted",
        "/etc/harness-panel/token with space",
    ] {
        let mut args = args();
        args.companion_auth_token_file = PathBuf::from(path);

        let error = render_unit("harness-panel", Path::new("/usr/bin/harness-panel"), &args)
            .expect_err("unsafe directive path must not render");

        assert!(error.to_string().contains("systemd directive"), "{error}");
    }
}

#[cfg(unix)]
#[test]
fn a_non_utf8_credential_path_is_refused() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt as _;

    let mut args = args();
    args.github_client_secret_file = PathBuf::from(OsString::from_vec(
        b"/etc/harness-panel/secret-\xff".to_vec(),
    ));

    let error = render_unit("harness-panel", Path::new("/usr/bin/harness-panel"), &args)
        .expect_err("a lossy path must not render");

    assert!(error.to_string().contains("valid UTF-8"), "{error}");
}

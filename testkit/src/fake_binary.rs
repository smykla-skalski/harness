use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Create an executable shell script that logs invocations and prints fixed stdout.
///
/// The script appends each invocation's arguments to `{dir}/{name}.invocations`.
///
/// # Panics
/// Panics if directory creation or file write fails.
#[must_use]
pub fn write_fake_binary(dir: &Path, name: &str, stdout: &str, exit_code: i32) -> PathBuf {
    let script = format!(
        "#!/bin/sh\necho \"$0 $*\" >> \"{dir}/{name}.invocations\"\nprintf '%s' '{stdout}'\nexit {exit_code}\n",
        dir = dir.display(),
        name = name,
        stdout = stdout.replace('\'', "'\\''"),
        exit_code = exit_code,
    );
    write_fake_binary_with_script(dir, name, &script)
}

/// Create an executable with arbitrary script content.
///
/// # Panics
/// Panics if directory creation or file write fails.
#[must_use]
pub fn write_fake_binary_with_script(dir: &Path, name: &str, script: &str) -> PathBuf {
    fs::create_dir_all(dir).expect("create fake binary dir");
    let path = dir.join(name);
    fs::write(&path, script).expect("write fake binary");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod fake binary");
    path
}

use std::env::{self, var_os};
use std::path::{Path, PathBuf};

use crate::workspace::host_home_dir;

#[must_use]
pub(super) fn resolve_program(program: &str) -> Option<PathBuf> {
    resolve_program_in_dirs(program, search_dirs())
}

fn resolve_program_in_dirs(program: &str, search_dirs: Vec<PathBuf>) -> Option<PathBuf> {
    let path = Path::new(program);
    if path.is_absolute() || program.contains('/') {
        return is_executable(path).then(|| path.to_path_buf());
    }

    search_dirs.into_iter().find_map(|directory| {
        let candidate = directory.join(program);
        is_executable(&candidate).then_some(candidate)
    })
}

fn search_dirs() -> Vec<PathBuf> {
    let home = host_home_dir();
    let mut dirs = vec![home.join(".local").join("bin"), home.join("bin")];
    if let Some(path_env) = var_os("PATH") {
        for directory in env::split_paths(&path_env) {
            push_unique_path(&mut dirs, directory);
        }
    }
    dirs
}

fn push_unique_path(dirs: &mut Vec<PathBuf>, candidate: PathBuf) {
    if candidate.as_os_str().is_empty() || dirs.iter().any(|existing| existing == &candidate) {
        return;
    }
    dirs.push(candidate);
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        path.metadata()
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }

    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_program_searches_user_local_bin_before_path() {
        let user_home = tempfile::tempdir().expect("home tempdir");
        let user_bin = user_home.path().join(".local/bin");
        let path_dir = tempfile::tempdir().expect("path tempdir");
        fs_err::create_dir_all(&user_bin).expect("create user bin");
        let user_binary = user_bin.join("fake-acp");
        let path_binary = path_dir.path().join("fake-acp");
        fs_err::write(&user_binary, "#!/bin/sh\nexit 0\n").expect("write user binary");
        fs_err::write(&path_binary, "#!/bin/sh\nexit 0\n").expect("write path binary");
        make_executable(&user_binary);
        make_executable(&path_binary);

        assert_eq!(
            resolve_program_in_dirs("fake-acp", vec![user_bin, path_dir.path().to_path_buf()])
                .as_deref(),
            Some(user_binary.as_path())
        );
    }

    #[test]
    fn resolve_program_falls_back_to_path() {
        let path_dir = tempfile::tempdir().expect("path tempdir");
        let binary = path_dir.path().join("fake-acp");
        fs_err::write(&binary, "#!/bin/sh\nexit 0\n").expect("write binary");
        make_executable(&binary);

        assert_eq!(
            resolve_program_in_dirs("fake-acp", vec![path_dir.path().to_path_buf()]).as_deref(),
            Some(binary.as_path())
        );
    }

    #[test]
    fn resolve_program_uses_host_home_before_path() {
        let host_home = tempfile::tempdir().expect("host home tempdir");
        let user_bin = host_home.path().join(".local/bin");
        fs_err::create_dir_all(&user_bin).expect("create user bin");
        let binary = user_bin.join("fake-acp");
        fs_err::write(&binary, "#!/bin/sh\nexit 0\n").expect("write binary");
        make_executable(&binary);

        temp_env::with_vars(
            [
                (
                    "HARNESS_HOST_HOME",
                    Some(host_home.path().to_str().expect("host home")),
                ),
                ("HOME", Some("/nonexistent-harness-home")),
                ("PATH", Some("/usr/bin:/bin")),
            ],
            || {
                assert_eq!(
                    resolve_program("fake-acp").as_deref(),
                    Some(binary.as_path())
                );
            },
        );
    }

    #[cfg(unix)]
    fn make_executable(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        let mut permissions = path.metadata().expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs_err::set_permissions(path, permissions).expect("set executable");
    }

    #[cfg(not(unix))]
    fn make_executable(_path: &Path) {}
}

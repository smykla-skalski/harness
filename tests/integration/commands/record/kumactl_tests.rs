use std::fs;

use harness::run::{KumactlArgs, KumactlCommand};

use super::super::super::helpers::*;
use super::kumactl_binary_dir;

#[test]
fn kumactl_find_returns_first_existing() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    let kumactl_dir = kumactl_binary_dir(&repo_root);
    fs::create_dir_all(&kumactl_dir).unwrap();
    fs::write(kumactl_dir.join("kumactl"), "#!/bin/sh\necho kumactl").unwrap();

    let cmd = KumactlCommand::Find {
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    };
    let result = kumactl_cmd(KumactlArgs { cmd }).execute();
    assert!(result.is_ok(), "kumactl find should succeed: {result:?}");
}

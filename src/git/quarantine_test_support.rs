use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};

pub(super) fn bundle_with_extra_blob(
    repository: &Path,
    valid_bundle: &[u8],
    revisions: &[&str],
    blob: &[u8],
) -> (Vec<u8>, String) {
    let object = git_with_input(repository, &["hash-object", "-w", "--stdin"], blob);
    let mut revision_args = vec!["rev-list", "--objects"];
    revision_args.extend_from_slice(revisions);
    let listed = git(repository, &revision_args);
    let mut object_ids = listed
        .lines()
        .filter_map(|line| line.split_ascii_whitespace().next())
        .collect::<Vec<_>>();
    object_ids.push(&object);
    let mut input = object_ids.join("\n").into_bytes();
    input.push(b'\n');
    let pack = git_bytes_with_input(
        repository,
        &["pack-objects", "--stdout", "--delta-base-offset"],
        &input,
    );
    let header_end = valid_bundle
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|index| index + 2)
        .expect("valid bundle header");
    let mut bytes = valid_bundle[..header_end].to_vec();
    bytes.extend_from_slice(&pack);
    (bytes, object)
}

fn git(repository: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output utf8")
        .trim()
        .to_owned()
}

fn git_with_input(repository: &Path, args: &[&str], input: &[u8]) -> String {
    String::from_utf8(git_bytes_with_input(repository, args, input))
        .expect("git output utf8")
        .trim()
        .to_owned()
}

fn git_bytes_with_input(repository: &Path, args: &[&str], input: &[u8]) -> Vec<u8> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run git with input");
    child
        .stdin
        .take()
        .expect("git stdin")
        .write_all(input)
        .expect("write git input");
    let output = child.wait_with_output().expect("wait for git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

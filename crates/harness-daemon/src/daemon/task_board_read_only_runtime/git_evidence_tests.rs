use std::process::Command;

use tempfile::tempdir;

use super::*;

fn git(path: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().into()
}

fn commit(path: &Path, file: &str, contents: &str) -> String {
    std::fs::write(path.join(file), contents).expect("write fixture");
    git(path, &["add", file]);
    git(
        path,
        &["-c", "commit.gpgsign=false", "commit", "-m", contents],
    );
    git(path, &["rev-parse", "HEAD"])
}

#[test]
fn implementation_head_must_descend_from_its_reported_base() {
    let temp = tempdir().expect("tempdir");
    git(temp.path(), &["init"]);
    git(temp.path(), &["config", "user.name", "Test User"]);
    git(temp.path(), &["config", "user.email", "test@example.com"]);
    let base = commit(temp.path(), "base.txt", "base");
    let descendant = commit(temp.path(), "result.txt", "result");
    assert!(
        local_result_descends_from_base(temp.path(), &result(base.as_str(), descendant.as_str()))
            .expect("descendant evidence")
    );

    git(temp.path(), &["checkout", "--orphan", "unrelated"]);
    git(temp.path(), &["rm", "-rf", "."]);
    let unrelated = commit(temp.path(), "unrelated.txt", "unrelated");
    assert!(
        !local_result_descends_from_base(temp.path(), &result(base.as_str(), unrelated.as_str()))
            .expect("unrelated evidence")
    );
}

fn result(base: &str, head: &str) -> TaskBoardImplementationResult {
    TaskBoardImplementationResult {
        revision_cycle: 1,
        base_head_revision: base.into(),
        head_revision: head.into(),
        summary: "implementation".into(),
        evidence: Vec::new(),
    }
}

use std::process::Command;

use super::helpers::repo_root;

#[test]
fn committed_cargo_lock_packages_are_name_sorted() {
    let root = repo_root();
    let output = Command::new("git")
        .args(["show", "HEAD:Cargo.lock"])
        .current_dir(root)
        .output()
        .expect("read committed Cargo.lock");
    assert!(
        output.status.success(),
        "git show HEAD:Cargo.lock failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lock = String::from_utf8(output.stdout).expect("Cargo.lock is UTF-8");
    let names = package_names(&lock);

    let out_of_order = names.windows(2).find_map(|pair| match pair {
        [previous, current] if previous > current => Some((previous, current)),
        _ => None,
    });
    if let Some((previous, current)) = out_of_order {
        panic!(
            "Cargo.lock package blocks are not canonical: {previous:?} sorts after {current:?}; run a mise Cargo task and commit the resulting Cargo.lock"
        );
    }
}

fn package_names(lock: &str) -> Vec<&str> {
    let mut expects_name = false;
    let mut names = Vec::new();
    for line in lock.lines() {
        if line == "[[package]]" {
            expects_name = true;
        } else if expects_name
            && let Some(name) = line
                .strip_prefix("name = \"")
                .and_then(|value| value.strip_suffix('"'))
        {
            names.push(name);
            expects_name = false;
        }
    }
    names
}

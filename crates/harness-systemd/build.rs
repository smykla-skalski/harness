use std::fs;
use std::path::Path;

fn main() {
    let manifest = include_str!("Cargo.toml");
    for forbidden in ["harness =", "harness-daemon ="] {
        assert!(
            !manifest
                .lines()
                .any(|line| line.trim_start().starts_with(forbidden)),
            "harness-systemd must not depend on {forbidden}"
        );
    }
    scan_source(Path::new("src"));
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=src");
}

fn scan_source(path: &Path) {
    for entry in fs::read_dir(path).expect("read harness-systemd source directory") {
        let entry = entry.expect("read harness-systemd source entry");
        let path = entry.path();
        if path.is_dir() {
            scan_source(&path);
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("rs") {
            continue;
        }
        let source = fs::read_to_string(&path).expect("read harness-systemd source file");
        assert!(
            !source.contains("src/daemon"),
            "{} path-includes the daemon implementation",
            path.display()
        );
    }
}

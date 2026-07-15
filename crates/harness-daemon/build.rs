use std::fs;
use std::path::Path;

fn main() {
    let manifest = include_str!("Cargo.toml");
    assert!(
        !manifest.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with("harness =") || line.starts_with("harness=")
        }),
        "harness-daemon must not depend on the root harness package"
    );
    scan_source(Path::new("src"));
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=src");
}

fn scan_source(path: &Path) {
    for entry in fs::read_dir(path).expect("read harness-daemon source directory") {
        let entry = entry.expect("read harness-daemon source entry");
        let path = entry.path();
        if path.is_dir() {
            scan_source(&path);
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("rs") {
            continue;
        }
        let source = fs::read_to_string(&path).expect("read harness-daemon source file");
        assert!(
            !source.contains("harness::") && !source.contains("src/lib.rs"),
            "{} imports the root harness source graph",
            path.display()
        );
    }
}

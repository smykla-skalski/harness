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
            !references_root_harness_crate(&source),
            "{} imports the root harness source graph",
            path.display()
        );
    }
}

/// The daemon subtree carries tracing target names (`"harness::daemon::db"`),
/// review/patch-parsing test fixtures (`"src/lib.rs"` as a stand-in file
/// path), and doc-comment prose that all echo the root crate's name without
/// depending on it, so a bare substring scan over the whole file flags real
/// code and inert text alike. Comments run to end of line here, so stripping
/// from the first `//` before splitting on `"` catches both: quoted spans
/// (odd-indexed after the split) are literals, not compiled paths.
fn references_root_harness_crate(source: &str) -> bool {
    source.lines().any(|line| {
        let code = line.split("//").next().unwrap_or("");
        code.split('"')
            .step_by(2)
            .any(|segment| segment.contains("harness::") || segment.contains("src/lib.rs"))
    })
}

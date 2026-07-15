fn main() {
    let manifest = include_str!("Cargo.toml");
    let depends_on_root = manifest.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("harness =") || line.starts_with("harness=")
    });
    assert!(
        !depends_on_root,
        "harness-bridge must not depend on the root harness package"
    );
    println!("cargo:rerun-if-changed=Cargo.toml");
}

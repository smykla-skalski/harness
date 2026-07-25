//! Builds the panel's web assets so the compiled binary can embed them.
//!
//! The panel ships as one executable, so `frontend/dist` has to exist before
//! `include_dir!` reads it. Doing that here rather than in a separate manual
//! step is what stops a binary from being built against whatever stale bundle
//! happened to be on disk.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Set this to build the binary without Node installed. The result serves a
/// placeholder page instead of the panel, and `healthz` reports it, so it is
/// only useful for compiling and testing the Rust side.
const SKIP_ENV: &str = "HARNESS_PANEL_SKIP_FRONTEND_BUILD";

/// Written next to the bundle so the asset handler and `healthz` can tell a
/// real build from the placeholder without guessing from the markup.
const PLACEHOLDER_MARKER: &str = ".harness-panel-placeholder";

fn main() {
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("cargo always sets CARGO_MANIFEST_DIR"),
    );
    let frontend = manifest_dir.join("frontend");
    let dist = frontend.join("dist");

    println!("cargo:rerun-if-env-changed={SKIP_ENV}");
    for input in [
        "src",
        "tests",
        "index.html",
        "package.json",
        "package-lock.json",
        "svelte.config.js",
        "tsconfig.json",
        "vite.config.ts",
    ] {
        println!("cargo:rerun-if-changed={}", frontend.join(input).display());
    }

    if env::var_os(SKIP_ENV).is_some() {
        write_placeholder(&dist);
        return;
    }

    install_dependencies(&frontend);
    run_npm(&frontend, &["run", "build"]);
    let marker = dist.join(PLACEHOLDER_MARKER);
    if marker.exists() {
        fs::remove_file(&marker).expect("removing the stale placeholder marker");
    }
}

/// `npm install` is skipped once the tree matches the lockfile, because the
/// build runs on every source change and a reinstall each time would dominate
/// it. The stamp lives beside `node_modules` so it is invalidated together with
/// the tree it describes.
fn install_dependencies(frontend: &Path) {
    let lockfile = frontend.join("package-lock.json");
    let stamp = frontend.join("node_modules").join(".harness-panel-stamp");
    let expected = fs::read(&lockfile).map_or_else(|_| String::new(), |bytes| digest(&bytes));

    if !expected.is_empty()
        && fs::read_to_string(&stamp).is_ok_and(|recorded| recorded.trim() == expected)
    {
        return;
    }

    run_npm(frontend, &["install", "--no-audit", "--no-fund"]);
    if !expected.is_empty() {
        fs::write(&stamp, expected).expect("recording the installed lockfile digest");
    }
}

fn run_npm(frontend: &Path, args: &[&str]) {
    let status = Command::new(npm_binary())
        .args(args)
        .current_dir(frontend)
        .status();
    match status {
        Ok(status) if status.success() => {}
        Ok(status) => panic!("npm {} failed with {status}", args.join(" ")),
        Err(error) => panic!(
            "could not run npm {} in {}: {error}. Install Node, or set {SKIP_ENV}=1 to build \
             without the panel's web assets.",
            args.join(" "),
            frontend.display()
        ),
    }
}

fn npm_binary() -> String {
    env::var("HARNESS_PANEL_NPM").unwrap_or_else(|_| "npm".to_owned())
}

fn write_placeholder(dist: &Path) {
    let assets = dist.join("assets");
    fs::create_dir_all(&assets).expect("creating the placeholder bundle directory");
    // `include_dir!` walks a real directory, and an empty one would compile to
    // a bundle with no entry point at all, so the placeholder has to be a page.
    fs::write(
        dist.join("index.html"),
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"harness-panel-base\" content=\"/__harness_panel_base__\">\
         <title>Harness panel</title></head><body>\
         <p>This binary was built without the panel's web assets.</p>\
         </body></html>\n",
    )
    .expect("writing the placeholder page");
    fs::write(dist.join(PLACEHOLDER_MARKER), "").expect("writing the placeholder marker");
    fs::write(assets.join(".keep"), "").expect("keeping the placeholder assets directory");
}

fn digest(bytes: &[u8]) -> String {
    // A build script cannot use the crate's own dependencies, and the stamp only
    // has to notice that the lockfile changed, so FNV-1a is enough here.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

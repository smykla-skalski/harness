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

/// Install exactly what the lockfile pins, and only when the installed tree no
/// longer matches it.
///
/// `npm ci` rather than `npm install`: `install` is free to resolve a different
/// tree and to rewrite `package-lock.json`, so an ordinary `cargo build` could
/// leave the working tree dirty and produce a binary nobody can reproduce.
/// The stamp lives beside `node_modules` so it is invalidated together with the
/// tree it describes, which keeps the reinstall off the common path where the
/// build already runs on every source change.
fn install_dependencies(frontend: &Path) {
    let lockfile = frontend.join("package-lock.json");
    let stamp = frontend.join("node_modules").join(".harness-panel-stamp");
    let expected = fs::read(&lockfile).map_or_else(|_| String::new(), |bytes| digest(&bytes));

    if !expected.is_empty()
        && fs::read_to_string(&stamp).is_ok_and(|recorded| recorded.trim() == expected)
    {
        return;
    }

    run_npm(frontend, &["ci", "--no-audit", "--no-fund"]);
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

/// Write a stand-in bundle that answers every route a real one does.
///
/// The point of the skip is to build and test the Rust side without Node, so
/// the placeholder has to satisfy the same expectations the real bundle does:
/// an entry page carrying the app's mount point, and one asset under the
/// content-hashed directory. A page that only apologised would make the tests
/// covering those routes fail for a reason that has nothing to do with them.
fn write_placeholder(dist: &Path) {
    // A previous real build leaves its hashed assets here, and Vite's own
    // `emptyOutDir` is what normally clears them. Without this the embedded
    // bundle would depend on build history rather than on this run.
    if dist.exists() {
        fs::remove_dir_all(dist).expect("clearing the previous bundle");
    }
    let assets = dist.join("assets");
    fs::create_dir_all(&assets).expect("creating the placeholder bundle directory");
    fs::write(
        dist.join("index.html"),
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"harness-panel-base\" content=\"/__harness_panel_base__\">\
         <title>Harness panel</title></head><body>\
         <div id=\"app\"><p>This binary was built without the panel's web assets.</p></div>\
         </body></html>\n",
    )
    .expect("writing the placeholder page");
    fs::write(dist.join(PLACEHOLDER_MARKER), "").expect("writing the placeholder marker");
    // Stands in for the content-hashed asset Vite emits, so the immutable cache
    // path is exercised rather than skipped when the frontend is absent.
    fs::write(
        assets.join("placeholder-0000000.js"),
        "/* built without the panel's web assets */\n",
    )
    .expect("writing the placeholder asset");
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

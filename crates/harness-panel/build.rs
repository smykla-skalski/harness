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

/// Overrides the npm the build script shells out to.
const NPM_ENV: &str = "HARNESS_PANEL_NPM";

/// Written next to the bundle so the asset handler and `healthz` can tell a
/// real build from the placeholder without guessing from the markup.
const PLACEHOLDER_MARKER: &str = ".harness-panel-placeholder";

fn main() {
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("cargo always sets CARGO_MANIFEST_DIR"),
    );
    let frontend = manifest_dir.join("frontend");
    let dist = frontend.join("dist");
    let installer = manifest_dir.join("../../scripts/install-panel-frontend.sh");
    let lock_helper = manifest_dir.join("../../scripts/lib/release-set.sh");

    // Both are read below, and a build script that declares any rerun-if
    // directive is rerun for those inputs alone, so an undeclared one looks
    // like an override that does nothing until something else changes.
    println!("cargo:rerun-if-env-changed={SKIP_ENV}");
    println!("cargo:rerun-if-env-changed={NPM_ENV}");
    println!("cargo:rerun-if-changed={}", installer.display());
    println!("cargo:rerun-if-changed={}", lock_helper.display());
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

    install_dependencies(&installer, &frontend);
    run_npm(&frontend, &["run", "build"]);
    let marker = dist.join(PLACEHOLDER_MARKER);
    if marker.exists() {
        fs::remove_file(&marker).expect("removing the stale placeholder marker");
    }
}

/// Use the same lock-aware installer as the frontend Mise tasks. On a fresh
/// checkout those tasks and this build script run in parallel, and two
/// independent `npm ci` processes delete each other's `node_modules`.
fn install_dependencies(installer: &Path, frontend: &Path) {
    let status = Command::new(installer)
        .env("HARNESS_PANEL_FRONTEND_DIR", frontend)
        .status();
    match status {
        Ok(status) if status.success() => {}
        Ok(status) => panic!("panel frontend dependency installation failed with {status}"),
        Err(error) => panic!(
            "could not run {}: {error}. Install Node, or set {SKIP_ENV}=1 to build without the \
             panel's web assets.",
            installer.display()
        ),
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
    env::var(NPM_ENV).unwrap_or_else(|_| "npm".to_owned())
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

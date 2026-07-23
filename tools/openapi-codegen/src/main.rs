//! Regenerate (or drift-check) the committed `OpenAPI` document for the daemon
//! HTTP API.
//!
//! Mirrors `examples/policy-codegen.rs`: with no flag it rewrites the checked-in
//! `docs/api/openapi.json`; with `--check` it compares the committed file to a
//! fresh render and exits non-zero on drift. The document itself is built by
//! `harness_daemon::daemon::http::openapi` from the annotated handlers.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const OUTPUT: &str = "docs/api/openapi.json";

fn repository_root() -> PathBuf {
    // The crate lives at tools/openapi-codegen; the repo root is two levels up.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("openapi-codegen manifest lives under tools/openapi-codegen")
        .to_path_buf()
}

fn main() -> ExitCode {
    let check = std::env::args().any(|arg| arg == "--check");
    let rendered = harness_daemon::daemon::http::openapi::openapi_json_string();
    let path = repository_root().join(OUTPUT);

    if check {
        let committed = match fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                eprintln!("drift: {OUTPUT} is missing - run `mise run openapi:generate`");
                return ExitCode::FAILURE;
            }
            Err(error) => {
                eprintln!("openapi-codegen: failed to read {OUTPUT}: {error}");
                return ExitCode::FAILURE;
            }
        };
        if committed != rendered {
            eprintln!("drift: {OUTPUT} is stale - run `mise run openapi:generate`");
            return ExitCode::FAILURE;
        }
        return ExitCode::SUCCESS;
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create docs/api directory");
    }
    fs::write(&path, rendered).expect("write docs/api/openapi.json");
    ExitCode::SUCCESS
}

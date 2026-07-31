//! Regenerate (or drift-check) the committed CLI references in `docs/cli/`.
//!
//! With no flag it rewrites the checked-in `docs/cli/*.md`; with `--check` it
//! compares the committed files to fresh renders and exits non-zero on drift.
//! Each reference renders from the owning binary's top-level clap parser, so
//! the document shares its source of truth with the runtime `--help` output.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::CommandFactory;

const OUTPUT_DIR: &str = "docs/cli";

fn repository_root() -> PathBuf {
    // The crate lives at tools/cli-docs-codegen; the repo root is two levels up.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("cli-docs-codegen manifest lives under tools/cli-docs-codegen")
        .to_path_buf()
}

struct BinaryDocs {
    name: &'static str,
    command: clap::Command,
}

fn binaries() -> Vec<BinaryDocs> {
    vec![
        BinaryDocs {
            name: "harness",
            command: harness::app::cli::Cli::command(),
        },
        BinaryDocs {
            name: "aff",
            command: aff::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-daemon",
            command: harness_daemon_bin::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-bridge",
            command: harness_bridge::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-hook",
            command: harness_hook::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-mcp",
            command: harness_mcp::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-panel",
            command: harness_panel::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-sybra",
            command: harness_sybra::cli::Cli::command(),
        },
        BinaryDocs {
            name: "harness-systemd",
            command: harness_systemd::Cli::command(),
        },
    ]
}

fn render(command: &clap::Command) -> String {
    format!("{}\n", clap_markdown::help_markdown_command(command))
}

fn main() -> ExitCode {
    let check = env::args().any(|arg| arg == "--check");
    let output_dir = repository_root().join(OUTPUT_DIR);
    let mut drifted = false;

    for binary in binaries() {
        let rendered = render(&binary.command);
        let path = output_dir.join(format!("{}.md", binary.name));
        if check {
            let committed = match fs::read_to_string(&path) {
                Ok(contents) => contents,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    eprintln!(
                        "drift: docs/cli/{}.md is missing - run `mise run cli-docs:generate`",
                        binary.name
                    );
                    drifted = true;
                    continue;
                }
                Err(error) => {
                    eprintln!("cli-docs-codegen: failed to read {}: {error}", path.display());
                    return ExitCode::FAILURE;
                }
            };
            if committed != rendered {
                eprintln!(
                    "drift: docs/cli/{}.md is stale - run `mise run cli-docs:generate`",
                    binary.name
                );
                drifted = true;
            }
        } else {
            fs::create_dir_all(&output_dir).expect("create docs/cli directory");
            fs::write(&path, rendered).expect("write docs/cli reference");
        }
    }

    if check && drifted {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

//! Regenerate (or drift-check) the committed CLI references in `docs/cli/`.
//!
//! With no flag it rewrites the checked-in `docs/cli/*.md`; with `--check` it
//! compares the committed files to fresh renders and exits non-zero on drift.
//! Each reference renders from the owning binary's top-level clap parser, so
//! the document shares its source of truth with the runtime `--help` output.

use std::collections::HashMap;
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

fn hidden_positionals(command: &clap::Command) -> Vec<String> {
    command
        .get_arguments()
        .filter(|arg| arg.is_positional() && arg.is_hide_set())
        .map(|arg| match arg.get_value_names() {
            Some([name, ..]) => name.to_string(),
            _ => arg.get_id().to_string().to_ascii_uppercase(),
        })
        .collect()
}

fn collect_hidden_by_path(
    command: &clap::Command,
    path: &str,
    hidden_by_path: &mut HashMap<String, Vec<String>>,
) {
    hidden_by_path.insert(path.to_owned(), hidden_positionals(command));
    for subcommand in command.get_subcommands() {
        collect_hidden_by_path(
            subcommand,
            &format!("{path} {}", subcommand.get_name()),
            hidden_by_path,
        );
    }
}

fn render(command: &clap::Command) -> String {
    let mut hidden_by_path = HashMap::new();
    collect_hidden_by_path(command, command.get_name(), &mut hidden_by_path);
    let markdown = clap_markdown::help_markdown_command(command);
    // `clap-markdown` renders hidden positionals despite `hide = true` (it
    // filters hidden flags, not hidden positionals), so drop those entries
    // per command section to keep the reference equal to `--help`. The crate
    // also pads empty descriptions with a trailing space and closes the
    // document with a blank line, both of which fail `git diff --check`, so
    // normalize the line endings here too.
    let mut current_hidden: &[String] = &[];
    let mut rendered = Vec::new();
    for line in markdown.lines() {
        if let Some(rest) = line.strip_prefix("## `").and_then(|rest| rest.strip_suffix('`')) {
            current_hidden = hidden_by_path.get(rest).map_or(&[], Vec::as_slice);
        }
        let hidden_entry = line.strip_prefix("* `<").is_some_and(|rest| {
            rest.split('>')
                .next()
                .is_some_and(|name| current_hidden.iter().any(|hidden| hidden == name))
        });
        if !hidden_entry {
            rendered.push(line.trim_end());
        }
    }
    format!("{}\n", rendered.join("\n"))
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<bool, String> {
    let check = match args.next().as_deref() {
        Some("--check") => true,
        Some(other) => return Err(format!("unexpected argument `{other}`")),
        None => false,
    };
    if let Some(other) = args.next() {
        return Err(format!("unexpected argument `{other}`"));
    }
    Ok(check)
}

fn main() -> ExitCode {
    let check = match parse_args(env::args().skip(1)) {
        Ok(check) => check,
        Err(message) => {
            eprintln!(
                "cli-docs-codegen: {message}; pass `--check` to drift-check instead of rewriting"
            );
            return ExitCode::FAILURE;
        }
    };
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

#[cfg(test)]
mod tests {
    use clap::Command;

    use super::*;

    #[test]
    fn hidden_positionals_are_omitted_but_visible_positionals_survive() {
        let command = Command::new("probe")
            .arg(clap::Arg::new("visible").value_name("VISIBLE"))
            .arg(clap::Arg::new("secret").value_name("SECRET").hide(true));
        let rendered = render(&command);
        assert!(rendered.contains("<VISIBLE>"));
        assert!(!rendered.contains("<SECRET>"));
    }
}

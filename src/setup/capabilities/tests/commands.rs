use std::collections::BTreeSet;

use clap::{CommandFactory, Subcommand, ValueEnum};

use crate::app::cli::Cli;
use crate::hooks::HookCommand;
use crate::hooks::adapters::HookAgent;
use crate::setup::wrapper::process_agent_registrations;

use super::*;

const HOOK_BINARY: &str = "harness-hook";

/// Every command string the report hands a reader, in the form they would type.
fn advertised_commands() -> Vec<String> {
    features()
        .values()
        .flat_map(|info| {
            info.command
                .iter()
                .chain(info.commands.iter().flatten())
                .cloned()
        })
        .collect()
}

/// Subcommands the shipped `harness-hook` binary answers to. The binary's own
/// parser lives in its `main.rs` and cannot be imported here, so this reads the
/// two surfaces that define it from this side: the tool-lifecycle `HookCommand`
/// parser it dispatches, and the lifecycle commands bootstrap writes into agent
/// runtime configs.
fn hook_subcommands() -> BTreeSet<String> {
    let parser = HookCommand::augment_subcommands(clap::Command::new(HOOK_BINARY));
    let mut names: BTreeSet<String> = parser
        .get_subcommands()
        .map(|subcommand| subcommand.get_name().to_string())
        .collect();
    names.extend(registered_hook_subcommands());
    names
}

fn registered_hook_subcommands() -> BTreeSet<String> {
    HookAgent::value_variants()
        .iter()
        .flat_map(|agent| process_agent_registrations(*agent))
        .filter_map(|registration| {
            let mut tokens = registration.command.split_whitespace();
            if tokens.next() == Some(HOOK_BINARY) {
                tokens.next().map(str::to_string)
            } else {
                None
            }
        })
        .collect()
}

/// Walks a clap command tree, so an advertised path resolves only while the CLI
/// still declares every segment of it.
fn resolves_in(command: &clap::Command, path: &[&str]) -> bool {
    match path.split_first() {
        None => true,
        Some((head, rest)) => command
            .find_subcommand(head)
            .is_some_and(|child| resolves_in(child, rest)),
    }
}

fn resolves(command: &str, cli: &clap::Command, hook_subcommands: &BTreeSet<String>) -> bool {
    let mut tokens = command.split_whitespace();
    let Some(binary) = tokens.next() else {
        return false;
    };
    let path: Vec<&str> = tokens.collect();
    match (binary, path.as_slice()) {
        ("harness", [_, ..]) => resolves_in(cli, &path),
        (HOOK_BINARY, [subcommand]) => hook_subcommands.contains(*subcommand),
        _ => false,
    }
}

#[test]
fn every_advertised_command_resolves_against_a_shipped_binary() {
    let cli = Cli::command();
    let hooks = hook_subcommands();
    let advertised = advertised_commands();
    assert!(
        !advertised.is_empty(),
        "the report advertises no commands at all, so this test proves nothing"
    );

    let unresolved: Vec<&String> = advertised
        .iter()
        .filter(|command| !resolves(command, &cli, &hooks))
        .collect();

    assert!(
        unresolved.is_empty(),
        "the report advertises commands no shipped binary accepts: {unresolved:?}"
    );
}

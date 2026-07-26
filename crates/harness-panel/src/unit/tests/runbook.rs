use std::iter;

use clap::{Args, Command};

use crate::config::PanelArgs;

const RUNBOOK: &str = include_str!("../../../../../docs/harness-panel.md");

#[test]
fn pair_and_upgrade_commands_supply_every_required_panel_flag() {
    let pair = lines_after("sudo harness-panel pair \\", 16);
    assert_required_panel_flags(&pair);
    assert!(pair.contains("--code-file"), "{pair}");

    let upgrading = RUNBOOK
        .split_once("## Upgrading")
        .expect("upgrading section")
        .1;
    let print_unit = lines_after_in(upgrading, "if ! \"$panel_candidate\" print-unit \\", 16);
    assert_required_panel_flags(&print_unit);
}

fn lines_after(anchor: &str, count: usize) -> String {
    lines_after_in(RUNBOOK, anchor, count)
}

fn lines_after_in(text: &str, anchor: &str, count: usize) -> String {
    let tail = text.split_once(anchor).expect("documented command").1;
    iter::once(anchor)
        .chain(tail.lines().take(count))
        .collect::<Vec<_>>()
        .join("\n")
}

fn assert_required_panel_flags(command_text: &str) {
    let command = PanelArgs::augment_args(Command::new("panel"));
    for argument in command
        .get_arguments()
        .filter(|argument| argument.is_required_set())
    {
        let Some(long) = argument.get_long() else {
            continue;
        };
        assert!(
            command_text.contains(&format!("--{long}")),
            "missing --{long} in:\n{command_text}"
        );
    }
}

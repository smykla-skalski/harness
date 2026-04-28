use std::path::Path;

use crate::agents::policy::DeniedBinaries;

pub(super) fn denied_binary_name(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    denied_binary_token(command, denied_binaries)
        .or_else(|| denied_shell_command(command, args, denied_binaries))
        .or_else(|| denied_env_command(command, args, denied_binaries))
}

fn denied_binary_token(token: &str, denied_binaries: &DeniedBinaries) -> Option<String> {
    let token = token.trim_matches(|c: char| matches!(c, '"' | '\'' | ';' | '(' | ')' | '&' | '|'));
    if denied_binaries.contains(token) {
        return Some(token.to_string());
    }
    let file_name = Path::new(token).file_name()?.to_str()?;
    denied_binaries
        .contains(file_name)
        .then(|| file_name.to_string())
}

fn denied_shell_command(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    let shell = Path::new(command).file_name()?.to_str()?;
    if !matches!(shell, "sh" | "bash" | "zsh") {
        return None;
    }
    let command_line = args
        .windows(2)
        .find_map(|window| (window[0] == "-c").then_some(window[1].as_str()))?;
    let first_command = command_line
        .split_whitespace()
        .find(|token| !matches!(*token, "exec" | "command"))?;
    denied_binary_token(first_command, denied_binaries)
}

fn denied_env_command(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    let command_name = Path::new(command).file_name()?.to_str()?;
    if command_name != "env" {
        return None;
    }
    let target = args
        .iter()
        .find(|arg| !arg.starts_with('-') && !arg.contains('='))?;
    denied_binary_token(target, denied_binaries)
}

use crate::kernel::command_intent::{ParsedCommand, is_env_assignment, normalized_binary_name};

use super::{
    SuggestedTask, command_segments, is_shell_interpreter, render_env_prefix,
    suggestions_for_segment, whole_command_suggestion,
};

pub(super) fn split_env_prefix<'a>(
    segment: &'a [String],
    inherited_env_prefix: &[String],
) -> (Vec<String>, &'a [String]) {
    let env_prefix_len = segment
        .iter()
        .take_while(|word| is_env_assignment(word))
        .count();
    let mut env_prefix = inherited_env_prefix.to_vec();
    env_prefix.extend_from_slice(&segment[..env_prefix_len]);
    (env_prefix, &segment[env_prefix_len..])
}

pub(super) fn wrapped_command(words: &[String]) -> Option<(Vec<String>, String)> {
    shell_wrapped_command(words)
        .or_else(|| rtk_shell_wrapped_command(words))
        .or_else(|| env_wrapped_command(words))
        .or_else(|| rtk_env_wrapped_command(words))
}

pub(super) fn wrapped_command_suggestions(
    command_text: &str,
    env_prefix: &[String],
) -> Vec<SuggestedTask> {
    let Ok(parsed) = ParsedCommand::parse(&normalize_shell_control_ops(command_text)) else {
        return Vec::new();
    };
    let direct_mise = direct_mise_suggestions(parsed.words(), env_prefix);
    if !direct_mise.is_empty() {
        return direct_mise;
    }
    whole_command_suggestion(parsed.words()).map_or_else(
        || suggested_tasks_with_prefix(parsed.words(), env_prefix),
        |suggestion| vec![prefix_suggestion(env_prefix, suggestion)],
    )
}

fn rtk_shell_wrapped_command(words: &[String]) -> Option<(Vec<String>, String)> {
    (normalized_binary_name(words.first()?) == "rtk")
        .then_some(())
        .and_then(|()| shell_wrapped_command(&words[1..]))
}

fn shell_wrapped_command(words: &[String]) -> Option<(Vec<String>, String)> {
    let head = normalized_binary_name(words.first()?);
    if !is_shell_interpreter(&head) {
        return None;
    }
    let command_index = words
        .iter()
        .position(|word| is_shell_command_flag(word))
        .and_then(|index| words.get(index + 1).map(|_| index + 1))?;
    Some((Vec::new(), words[command_index].clone()))
}

fn env_wrapped_command(words: &[String]) -> Option<(Vec<String>, String)> {
    (normalized_binary_name(words.first()?) == "env")
        .then_some(())
        .and_then(|()| wrapper_command_after_assignments(&words[1..]))
}

fn rtk_env_wrapped_command(words: &[String]) -> Option<(Vec<String>, String)> {
    (normalized_binary_name(words.first()?) == "rtk" && words.get(1)? == "env")
        .then_some(())
        .and_then(|()| wrapper_command_after_assignments(&words[2..]))
}

fn wrapper_command_after_assignments(words: &[String]) -> Option<(Vec<String>, String)> {
    let assignment_len = words
        .iter()
        .take_while(|word| is_env_assignment(word))
        .count();
    let command_words = words.get(assignment_len..)?;
    if command_words.is_empty() {
        return None;
    }
    if normalized_binary_name(&command_words[0]) == "mise" {
        return None;
    }
    Some((
        words[..assignment_len].to_vec(),
        shell_words::join(command_words.iter().map(String::as_str)),
    ))
}

fn suggested_tasks_with_prefix(words: &[String], env_prefix: &[String]) -> Vec<SuggestedTask> {
    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        suggestions.extend(suggestions_for_segment(segment, env_prefix));
    }
    suggestions
}

fn direct_mise_suggestions(words: &[String], env_prefix: &[String]) -> Vec<SuggestedTask> {
    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        if let Some(suggestion) = direct_mise_suggestion_for_segment(segment, env_prefix) {
            suggestions.push(suggestion);
        }
    }
    suggestions
}

fn direct_mise_suggestion_for_segment(
    segment: &[String],
    env_prefix: &[String],
) -> Option<SuggestedTask> {
    let (nested_env_prefix, nested_words) = split_env_prefix(segment, env_prefix);
    (normalized_binary_name(nested_words.first()?) == "mise").then(|| SuggestedTask {
        replacement: format!(
            "{}{}",
            render_env_prefix(&nested_env_prefix),
            shell_words::join(nested_words.iter().map(String::as_str))
        ),
    })
}

fn prefix_suggestion(env_prefix: &[String], suggestion: SuggestedTask) -> SuggestedTask {
    if env_prefix.is_empty() {
        return suggestion;
    }
    SuggestedTask {
        replacement: format!(
            "{}{}",
            render_env_prefix(env_prefix),
            suggestion.replacement
        ),
    }
}

fn is_shell_command_flag(flag: &str) -> bool {
    flag.starts_with('-')
        && flag.contains('c')
        && flag
            .chars()
            .skip(1)
            .all(|part| matches!(part, 'c' | 'i' | 'l' | 's'))
}

fn normalize_shell_control_ops(text: &str) -> String {
    text.replace("&&", " && ")
        .replace("||", " || ")
        .replace(';', " ; ")
        .replace('|', " | ")
}

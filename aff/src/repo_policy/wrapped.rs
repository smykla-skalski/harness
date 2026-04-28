use crate::command_intent::{
    ParsedCommand, is_env_assignment, normalized_binary_name, parse_supported_command_text,
};

/// Supported wrapper boundary:
/// - optional leading `rtk`
/// - `env VAR=... <command ...>` wrappers
/// - `bash|sh|zsh|fish -c|-lc|-ic|-lc '<command ...>'` wrappers
///
/// We intentionally reject clever shells beyond those shapes. In particular,
/// wrapped command strings must already tokenize cleanly with `shell_words`
/// and any shell control operators inside them must be standalone tokens
/// (`cmd && other`, not `cmd&&other`). Rejecting ambiguous forms is safer than
/// guessing and accidentally allowing a repo-managed command to slip through.
pub(super) fn wrapped_command(
    words: &[String],
) -> Result<Option<(Vec<String>, ParsedCommand)>, String> {
    let words = strip_rtk(words);
    if words.is_empty() {
        return Ok(None);
    }

    if normalized_binary_name(&words[0]) == "env" {
        return parse_env_wrapper(&words[1..]);
    }
    if is_shell_interpreter(&normalized_binary_name(&words[0])) {
        return parse_shell_wrapper(words, Vec::new());
    }
    Ok(None)
}

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

fn strip_rtk(words: &[String]) -> &[String] {
    if words
        .first()
        .is_some_and(|word| normalized_binary_name(word) == "rtk")
    {
        &words[1..]
    } else {
        words
    }
}

fn parse_env_wrapper(words: &[String]) -> Result<Option<(Vec<String>, ParsedCommand)>, String> {
    let assignment_len = words
        .iter()
        .take_while(|word| is_env_assignment(word))
        .count();
    if assignment_len == words.len() {
        return Err(
            "unsupported wrapped shell command shape: env wrapper must include a nested command"
                .to_string(),
        );
    }

    let env_prefix = words[..assignment_len].to_vec();
    let nested_words = &words[assignment_len..];
    let nested_words = strip_rtk(nested_words);
    if nested_words.is_empty() {
        return Err(
            "unsupported wrapped shell command shape: env wrapper must include a nested command"
                .to_string(),
        );
    }

    if is_shell_interpreter(&normalized_binary_name(&nested_words[0])) {
        parse_shell_wrapper(nested_words, env_prefix)
    } else {
        let command_text = shell_words::join(nested_words.iter().map(String::as_str));
        let parsed = parse_wrapped_command_text(&command_text)?;
        Ok(Some((env_prefix, parsed)))
    }
}

fn parse_shell_wrapper(
    words: &[String],
    env_prefix: Vec<String>,
) -> Result<Option<(Vec<String>, ParsedCommand)>, String> {
    if words.is_empty() {
        return Ok(None);
    }
    let head = normalized_binary_name(&words[0]);
    if !is_shell_interpreter(&head) {
        return Ok(None);
    }

    let Some(command_index) = shell_command_index(words) else {
        return Err(
            "unsupported wrapped shell command shape: shell wrappers must use a single -c style flag followed by one command string".to_string(),
        );
    };
    if command_index + 1 != words.len() {
        return Err(
            "unsupported wrapped shell command shape: shell wrappers may only pass one command string after the -c style flag".to_string(),
        );
    }

    let parsed = parse_wrapped_command_text(&words[command_index])?;
    Ok(Some((env_prefix, parsed)))
}

fn shell_command_index(words: &[String]) -> Option<usize> {
    let mut command_index = None;
    for (index, word) in words.iter().enumerate().skip(1) {
        if is_shell_command_flag(word) {
            if command_index.is_some() {
                return None;
            }
            command_index = Some(index + 1);
        }
    }
    command_index.filter(|index| *index < words.len())
}

fn parse_wrapped_command_text(command_text: &str) -> Result<ParsedCommand, String> {
    parse_supported_command_text(command_text, "wrapped shell")
}

fn is_shell_interpreter(head: &str) -> bool {
    matches!(head, "bash" | "fish" | "sh" | "zsh")
}

fn is_shell_command_flag(flag: &str) -> bool {
    flag.starts_with('-')
        && flag.contains('c')
        && flag
            .chars()
            .skip(1)
            .all(|part| matches!(part, 'c' | 'i' | 'l' | 's'))
}

#[cfg(test)]
mod tests {
    use super::wrapped_command;

    fn words(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_string()).collect()
    }

    #[test]
    fn parses_supported_shell_wrapper() {
        let wrapped = wrapped_command(&words(&["bash", "-lc", "mise run check"]))
            .expect("wrapper should parse")
            .expect("wrapper should be recognized");
        assert_eq!(wrapped.1.words(), ["mise", "run", "check"]);
    }

    #[test]
    fn rejects_shell_wrapper_with_embedded_control_operator() {
        let error = wrapped_command(&words(&["bash", "-lc", "mise run check&&mise run test"]))
            .expect_err("unsupported shell wrapper should fail");
        assert!(error.contains("unsupported wrapped shell command shape"));
    }
}

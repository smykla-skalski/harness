use std::path::Path;

use super::shell::is_shell_control_op;

/// Flags that tell kubectl to consume the next token as a value rather than a
/// positional resource argument.
const KUBECTL_FLAGS_WITH_VALUE: [&str; 7] = [
    "-o",
    "-n",
    "--namespace",
    "--output",
    "-l",
    "--selector",
    "--field-selector",
];

pub(crate) fn collect_kubectl_positional_args(tokens: &[String]) -> Vec<&str> {
    let mut positional = Vec::new();
    let mut skip_next = false;

    for token in tokens {
        if skip_next {
            skip_next = false;
            continue;
        }
        if is_shell_control_op(token) {
            break;
        }
        if KUBECTL_FLAGS_WITH_VALUE.contains(&token.as_str()) {
            skip_next = true;
            continue;
        }
        if token.starts_with('-') {
            continue;
        }
        positional.push(token.as_str());
        if positional.len() == 2 {
            break;
        }
    }

    positional
}

pub(crate) fn fallback_harness_spans<'a>(
    words: &'a [String],
    significant_word_indices: &[usize],
) -> Vec<Vec<&'a str>> {
    let mut spans = Vec::new();
    let len = significant_word_indices.len();
    for (index, &word_index) in significant_word_indices.iter().enumerate() {
        let word = &words[word_index];
        let head = Path::new(word)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(word.as_str());
        if head != "harness" {
            continue;
        }
        let search_end = next_harness_index(words, significant_word_indices, index).unwrap_or(len);
        let span = semantic_fallback_span(words, &significant_word_indices[index + 1..search_end]);
        spans.push(span);
    }
    spans
}

fn next_harness_index(
    words: &[String],
    significant_word_indices: &[usize],
    start_index: usize,
) -> Option<usize> {
    significant_word_indices[start_index + 1..]
        .iter()
        .position(|&candidate_index| {
            Path::new(&words[candidate_index])
                .file_name()
                .and_then(|name| name.to_str())
                == Some("harness")
        })
        .map(|offset| start_index + 1 + offset)
}

fn semantic_fallback_span<'a>(words: &'a [String], span_indices: &[usize]) -> Vec<&'a str> {
    let mut span: Vec<&str> = span_indices
        .iter()
        .map(|&span_index| words[span_index].as_str())
        .collect();
    if matches!(span.first(), Some(&"run" | &"setup" | &"create")) && span.len() > 1 {
        span.remove(0);
    }
    if matches!(span.first(), Some(&"kuma")) && span.len() > 1 {
        span.remove(0);
    }
    span
}

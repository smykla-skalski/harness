use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn assert_file_lacks_needles(contents: &str, message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(!contents.contains(needle), "{message_prefix} `{needle}`");
    }
}

pub(super) fn assert_file_contains_needles(contents: &str, message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(contents.contains(needle), "{message_prefix} `{needle}`");
    }
}

pub(super) fn assert_docs_contain_needles(docs: &[&str], message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            docs.iter().any(|doc| doc.contains(needle)),
            "{message_prefix} `{needle}`"
        );
    }
}

pub(super) fn read_repo_file(root: &Path, path: &str) -> String {
    let resolved = resolve_repo_path(root, path).unwrap_or_else(|| {
        panic!("repo path not found: {path}");
    });
    fs::read_to_string(resolved).unwrap()
}

pub(super) fn repo_path_exists(root: &Path, path: &str) -> bool {
    resolve_repo_path(root, path).is_some()
}

fn resolve_repo_path(root: &Path, path: &str) -> Option<PathBuf> {
    candidate_repo_paths(root, path)
        .into_iter()
        .find(|candidate| candidate.exists())
}

fn candidate_repo_paths(root: &Path, path: &str) -> Vec<PathBuf> {
    let mut candidates = vec![root.join(path)];
    if let Some(base) = path.strip_suffix(".rs") {
        candidates.push(root.join(base).join("mod.rs"));
    } else {
        candidates.push(root.join(path).join("mod.rs"));
    }
    candidates
}

pub(super) fn collect_hits_in_paths<F>(
    root: &Path,
    paths: &[&str],
    needles: &[&str],
    render: F,
) -> Vec<String>
where
    F: Fn(&str, &str) -> String,
{
    let mut hits = Vec::new();
    for path in paths {
        let contents = read_repo_file(root, path);
        for needle in needles {
            if contents.contains(needle) {
                hits.push(render(path, needle));
            }
        }
    }
    hits
}

pub(super) fn collect_hits_in_tree<F>(
    start: &Path,
    root: &Path,
    skip_prefix: Option<&Path>,
    needles: &[&str],
    render: F,
) -> Vec<String>
where
    F: Fn(&str, &str) -> String,
{
    let mut hits = Vec::new();

    for entry in walkdir::WalkDir::new(start)
        .into_iter()
        .filter_map(Result::ok)
    {
        let child = entry.into_path();
        if skip_prefix.is_some_and(|prefix| child.starts_with(prefix)) || child.is_dir() {
            continue;
        }
        if !matches_extension(&child) {
            continue;
        }
        let contents = fs::read_to_string(&child).unwrap();
        let relative = child.strip_prefix(root).unwrap().display().to_string();
        for needle in needles {
            if contents.contains(needle) {
                hits.push(render(&relative, needle));
            }
        }
    }

    hits
}

/// Like [`collect_hits_in_tree`], but blind to Rust comments.
///
/// Use this when the rule forbids a *construct*. Prose that names the construct
/// is not a violation, and recording why a lint decision was made is something
/// we want people to do, so a raw substring match over source punishes exactly
/// the comment the rule wanted written.
pub(super) fn collect_code_hits_in_tree<F>(
    start: &Path,
    root: &Path,
    skip_prefix: Option<&Path>,
    needles: &[&str],
    render: F,
) -> Vec<String>
where
    F: Fn(&str, &str) -> String,
{
    let mut hits = Vec::new();

    for entry in walkdir::WalkDir::new(start)
        .into_iter()
        .filter_map(Result::ok)
    {
        let child = entry.into_path();
        if skip_prefix.is_some_and(|prefix| child.starts_with(prefix)) || child.is_dir() {
            continue;
        }
        if !matches_extension(&child) {
            continue;
        }
        let raw = fs::read_to_string(&child).unwrap();
        let contents = if child.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            strip_rust_comments(&raw)
        } else {
            raw
        };
        let relative = child.strip_prefix(root).unwrap().display().to_string();
        for needle in needles {
            if contents.contains(needle) {
                hits.push(render(&relative, needle));
            }
        }
    }

    hits
}

/// Drop Rust comments, keeping string literals verbatim.
///
/// String contents have to survive: a guard that forbids shelling out to a tool
/// is looking for that tool's name inside a string, so stripping literals would
/// silently retire the rule. Newlines are preserved so removing a trailing
/// comment cannot splice two lines into a match that never existed.
pub(super) fn strip_rust_comments(source: &str) -> String {
    let mut out = String::with_capacity(source.len());
    let mut in_string = false;
    let mut escaped = false;
    let mut block_depth = 0usize;

    for line in source.split_inclusive('\n') {
        let mut chars = line.char_indices().peekable();
        while let Some((index, current)) = chars.next() {
            let next = line[index..].chars().nth(1);

            if block_depth > 0 {
                if current == '*' && next == Some('/') {
                    block_depth -= 1;
                    chars.next();
                } else if current == '/' && next == Some('*') {
                    block_depth += 1;
                    chars.next();
                }
                continue;
            }

            if in_string {
                out.push(current);
                if escaped {
                    escaped = false;
                } else if current == '\\' {
                    escaped = true;
                } else if current == '"' {
                    in_string = false;
                }
                continue;
            }

            match (current, next) {
                ('/', Some('/')) => break,
                ('/', Some('*')) => {
                    block_depth += 1;
                    chars.next();
                }
                ('"', _) => {
                    in_string = true;
                    out.push(current);
                }
                _ => out.push(current),
            }
        }
        out.push('\n');
    }

    out
}

pub(super) fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("rs" | "snap" | "md")
    )
}

#[cfg(test)]
mod strip_rust_comments_tests {
    use super::strip_rust_comments;

    /// Built at runtime so this file does not trip the guards it supports.
    fn allow_needle() -> String {
        ["allow", "(clippy::"].concat()
    }

    #[test]
    fn prose_naming_a_lint_attribute_is_not_a_hit() {
        let needle = allow_needle();
        let source = format!("/// retired the blanket `{needle}large_futures)`\npub fn f() {{}}\n");
        assert!(!strip_rust_comments(&source).contains(&needle));
    }

    #[test]
    fn a_real_attribute_is_still_a_hit() {
        let needle = allow_needle();
        let source = format!("#[{needle}large_futures)]\npub fn f() {{}}\n");
        assert!(strip_rust_comments(&source).contains(&needle));
    }

    #[test]
    fn block_comments_are_dropped_across_lines() {
        let needle = allow_needle();
        let source = format!("/* one\n {needle}x)\n two */\npub fn f() {{}}\n");
        let stripped = strip_rust_comments(&source);
        assert!(!stripped.contains(&needle));
        assert!(stripped.contains("pub fn f()"));
    }

    #[test]
    fn string_literals_survive_so_process_guards_still_fire() {
        let tool = ["pk", "ill"].concat();
        let source = format!("let cmd = \"{tool} -f harness\";\n");
        assert!(strip_rust_comments(&source).contains(&tool));
    }

    #[test]
    fn a_double_slash_inside_a_string_does_not_start_a_comment() {
        let source = "let url = \"https://example.com/x\";\nlet keep = 1;\n";
        let stripped = strip_rust_comments(source);
        assert!(stripped.contains("https://example.com/x"));
        assert!(stripped.contains("let keep = 1;"));
    }

    #[test]
    fn a_trailing_comment_does_not_splice_the_next_line() {
        let source = "let a = 1; // tail\nlet b = 2;\n";
        let stripped = strip_rust_comments(source);
        assert!(!stripped.contains("tail"));
        assert!(stripped.contains("let a = 1;"));
        assert!(stripped.contains("let b = 2;"));
    }
}

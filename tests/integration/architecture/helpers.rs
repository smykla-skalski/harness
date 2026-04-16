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

pub(super) fn assert_docs_lack_needles(docs: &[&str], message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            !docs.iter().any(|doc| doc.contains(needle)),
            "{message_prefix} `{needle}`"
        );
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

pub(super) fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("rs" | "snap" | "md")
    )
}

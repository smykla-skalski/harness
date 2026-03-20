use std::fs;
use std::path::Path;

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
    fs::read_to_string(root.join(path)).unwrap()
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

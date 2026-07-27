use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("architecture-test crate lives under tools")
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
        let contents = fs::read_to_string(root.join(path))
            .unwrap_or_else(|error| panic!("read {path}: {error}"));
        collect_hits(&mut hits, path, &contents, needles, &render);
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
    let mut files = Vec::new();
    collect_files(start, skip_prefix, &mut files);

    let mut hits = Vec::new();
    for file in files {
        let contents = fs::read_to_string(&file)
            .unwrap_or_else(|error| panic!("read {}: {error}", file.display()));
        let relative = file
            .strip_prefix(root)
            .expect("scanned file stays under the repository root")
            .display()
            .to_string();
        collect_hits(&mut hits, &relative, &contents, needles, &render);
    }
    hits
}

fn collect_files(start: &Path, skip_prefix: Option<&Path>, files: &mut Vec<PathBuf>) {
    let entries =
        fs::read_dir(start).unwrap_or_else(|error| panic!("read {}: {error}", start.display()));
    for entry in entries {
        let entry = entry.expect("read directory entry");
        let file_type = entry.file_type().expect("read directory entry type");
        let path = entry.path();
        if skip_prefix.is_some_and(|prefix| path.starts_with(prefix)) {
            continue;
        }
        if file_type.is_dir() {
            collect_files(&path, skip_prefix, files);
        } else if file_type.is_file() && matches_extension(&path) {
            files.push(path);
        }
    }
}

fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|extension| extension.to_str()),
        Some("rs" | "snap" | "md")
    )
}

fn collect_hits<F>(hits: &mut Vec<String>, path: &str, contents: &str, needles: &[&str], render: &F)
where
    F: Fn(&str, &str) -> String,
{
    for needle in needles {
        if contents.contains(needle) {
            hits.push(render(path, needle));
        }
    }
}

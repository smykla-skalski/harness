use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

const MAX_FILE_LINES: usize = 520;
const TRACKED_RUST_TOP_LEVEL_DIRS: &[&str] = &["src", "tests", "testkit"];

fn main() {
    let repo_root = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("cargo must set CARGO_MANIFEST_DIR for build.rs"),
    );

    emit_rerun_instructions(&repo_root);

    let tracked_files = tracked_rust_files(&repo_root).unwrap_or_else(|error| {
        panic!("failed to discover tracked Rust files for file-length enforcement: {error}")
    });
    let violations = oversized_files(&repo_root, &tracked_files).unwrap_or_else(|error| {
        panic!("failed to scan tracked Rust files for file-length enforcement: {error}")
    });

    assert!(
        violations.is_empty(),
        "{}",
        format_violation_report(&violations)
    );
}

fn emit_rerun_instructions(repo_root: &Path) {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=clippy.toml");

    for directory in TRACKED_RUST_TOP_LEVEL_DIRS {
        if repo_root.join(directory).exists() {
            println!("cargo:rerun-if-changed={directory}");
        }
    }
}

fn tracked_rust_files(repo_root: &Path) -> io::Result<Vec<PathBuf>> {
    tracked_rust_files_via_git(repo_root).or_else(|_| tracked_rust_files_via_walk(repo_root))
}

fn tracked_rust_files_via_git(repo_root: &Path) -> io::Result<Vec<PathBuf>> {
    let output = Command::new("git")
        .current_dir(repo_root)
        .args(["ls-files", "--", "*.rs"])
        .output()?;

    if !output.status.success() {
        return Err(io::Error::other(format!(
            "git ls-files failed with status {}",
            output.status
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut files = stdout
        .lines()
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .map(|path| repo_root.join(path))
        .collect::<Vec<_>>();

    files.sort();
    Ok(files)
}

fn tracked_rust_files_via_walk(repo_root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut files = Vec::new();

    for directory in TRACKED_RUST_TOP_LEVEL_DIRS {
        let path = repo_root.join(directory);
        if path.exists() {
            collect_rust_files(&path, &mut files)?;
        }
    }

    files.sort();
    Ok(files)
}

fn collect_rust_files(path: &Path, files: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_path = entry.path();

        if entry.file_type()?.is_dir() {
            collect_rust_files(&entry_path, files)?;
            continue;
        }

        if entry_path.extension() == Some(OsStr::new("rs")) {
            files.push(entry_path);
        }
    }

    Ok(())
}

fn oversized_files(
    repo_root: &Path,
    tracked_files: &[PathBuf],
) -> io::Result<Vec<(String, usize)>> {
    let mut violations = Vec::new();

    for file in tracked_files {
        let contents = fs::read_to_string(file)?;
        let line_count = line_count(&contents);
        if line_count > MAX_FILE_LINES {
            let relative_path = file
                .strip_prefix(repo_root)
                .unwrap_or(file)
                .display()
                .to_string();
            violations.push((relative_path, line_count));
        }
    }

    violations.sort_by(|(left_path, left_lines), (right_path, right_lines)| {
        right_lines
            .cmp(left_lines)
            .then_with(|| left_path.cmp(right_path))
    });
    Ok(violations)
}

fn line_count(contents: &str) -> usize {
    if contents.is_empty() {
        return 0;
    }

    let newline_count = contents.match_indices('\n').count();
    newline_count + usize::from(!contents.ends_with('\n'))
}

fn format_violation_report(violations: &[(String, usize)]) -> String {
    let details = violations
        .iter()
        .map(|(path, lines)| format!("  {lines:>4}  {path}"))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "Rust source file length limit exceeded.\n\
         Clippy does not currently provide a stable file-level line-count lint, so \
         build.rs enforces the repo-wide maximum of {MAX_FILE_LINES} lines and \
         makes `cargo clippy --lib` fail with the full violation list.\n\n\
         Violations ({count}):\n{details}",
        count = violations.len()
    )
}

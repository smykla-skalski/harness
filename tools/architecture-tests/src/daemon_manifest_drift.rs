//! `crates/harness-daemon/src/lib.rs` still compiles four root `src/` trees
//! directly through `#[path]` (`daemon`, `feature_flags`, `reviews`,
//! `task_board`) instead of depending on a crate for them. The root crate
//! and `harness-daemon` each declare their own dependencies and features for
//! that same source, and nothing keeps the two manifests in step: a change
//! under one of these trees that starts needing a new crate or feature
//! builds cleanly in whichever crate its author is testing and leaves the
//! other broken, discovered later by someone on an unrelated branch.
//!
//! This check only watches the four trees above. Everything that used to be
//! `#[path]`-mirrored alongside them already moved to a real crate
//! dependency, where `cargo` itself keeps the manifests honest.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use super::helpers::repo_root;

const MIRRORED_ROOTS: &[&str] = &[
    "src/daemon",
    "src/reviews",
    "src/task_board",
    "src/feature_flags.rs",
];
const ROOT_MANIFEST: &str = "Cargo.toml";
const DAEMON_MANIFEST: &str = "crates/harness-daemon/Cargo.toml";

#[test]
fn daemon_mirrored_source_stays_declared_in_both_manifests() {
    let root = repo_root();
    let root_manifest = fs::read_to_string(root.join(ROOT_MANIFEST))
        .unwrap_or_else(|error| panic!("read {ROOT_MANIFEST}: {error}"));
    let daemon_manifest = fs::read_to_string(root.join(DAEMON_MANIFEST))
        .unwrap_or_else(|error| panic!("read {DAEMON_MANIFEST}: {error}"));

    let root_deps = manifest_dependency_idents(&root_manifest);
    let daemon_deps = manifest_dependency_idents(&daemon_manifest);
    let root_features = manifest_feature_names(&root_manifest);
    let daemon_features = manifest_feature_names(&daemon_manifest);
    let known_deps: BTreeSet<&String> = root_deps.union(&daemon_deps).collect();
    let known_features: BTreeSet<&String> = root_features.union(&daemon_features).collect();

    let mut files = Vec::new();
    for mirrored in MIRRORED_ROOTS {
        collect_rs_files(&root.join(mirrored), &mut files);
    }
    let cfg_test_only_child_modules = cfg_test_only_child_modules(&files);

    let mut used_deps = BTreeSet::new();
    let mut used_features = BTreeSet::new();
    for file in &files {
        let contents = fs::read_to_string(file)
            .unwrap_or_else(|error| panic!("read {}: {error}", file.display()));
        // Features gate compilation modes, not test-vs-production code, so every
        // occurrence counts regardless of which file or block it sits in.
        used_features.extend(used_cfg_feature_names(&contents));

        let relative = file
            .strip_prefix(root)
            .expect("scanned file stays under the repository root");
        if is_test_only_path(relative) || is_declared_test_only(file, &cfg_test_only_child_modules)
        {
            continue;
        }
        // A file that mixes production code with an inline `#[cfg(test)] mod
        // tests { .. }` block only needs its production half held to both
        // manifests: `harness-daemon`'s lib disables every mirrored test target
        // outright (`#![cfg(not(test))]`), so a dev-only crate used solely in
        // that block never needs declaring there.
        let production_only = strip_cfg_test_blocks(&contents);
        used_deps.extend(used_crate_idents(&production_only));
    }

    let mut hits = Vec::new();
    for name in &used_deps {
        if !known_deps.contains(name) {
            continue;
        }
        if !root_deps.contains(name) {
            hits.push(format!(
                "`{name}` is a dependency in {DAEMON_MANIFEST} and is used under a daemon-mirrored path, but {ROOT_MANIFEST} does not declare it"
            ));
        }
        if !daemon_deps.contains(name) {
            hits.push(format!(
                "`{name}` is a dependency in {ROOT_MANIFEST} and is used under a daemon-mirrored path, but {DAEMON_MANIFEST} does not declare it"
            ));
        }
    }
    for name in &used_features {
        if !known_features.contains(name) {
            continue;
        }
        if !root_features.contains(name) {
            hits.push(format!(
                "`{name}` is a feature in {DAEMON_MANIFEST} and is checked under a daemon-mirrored path, but {ROOT_MANIFEST} does not declare it"
            ));
        }
        if !daemon_features.contains(name) {
            hits.push(format!(
                "`{name}` is a feature in {ROOT_MANIFEST} and is checked under a daemon-mirrored path, but {DAEMON_MANIFEST} does not declare it"
            ));
        }
    }

    assert!(
        hits.is_empty(),
        "crates/harness-daemon/src/lib.rs `#[path]`-mirrors {MIRRORED_ROOTS:?} from the root crate; \
         keep both manifests declaring what that source uses:\n{}",
        hits.join("\n")
    );
}

fn collect_rs_files(start: &Path, files: &mut Vec<PathBuf>) {
    if start.is_file() {
        files.push(start.to_path_buf());
        return;
    }
    let entries =
        fs::read_dir(start).unwrap_or_else(|error| panic!("read {}: {error}", start.display()));
    for entry in entries {
        let entry = entry.expect("read directory entry");
        let path = entry.path();
        if entry
            .file_type()
            .expect("read directory entry type")
            .is_dir()
        {
            collect_rs_files(&path, files);
        } else if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            files.push(path);
        }
    }
}

/// A whole file dedicated to tests never needs to build under
/// `harness-daemon`, which disables every mirrored test target wholesale.
/// Matches this repository's own naming convention for such a file: any
/// path segment or `_`-delimited part of a filename that is exactly `tests`
/// (`tests.rs`, `foo_tests.rs`, anything under a `tests/` directory).
/// Deliberately excludes the singular `test`: this tree also has several
/// `test_support.rs` / `test_seam.rs` files, and not all of them are
/// test-only - `src/daemon/client/test_support.rs` is declared under
/// `#[cfg(any(test, feature = "daemon-runtime"))]`, so it is genuinely
/// production code once that feature is active. `is_declared_test_only`
/// below covers the ones that really are test-only despite the singular
/// name.
fn is_test_only_path(relative: &Path) -> bool {
    relative.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(|component| component.split(['_', '.']).any(|token| token == "tests"))
    })
}

/// A file that some *other* mirrored file declares as a bare `#[cfg(test)]
/// mod <name>;` never needs to build under `harness-daemon` either, exactly
/// like a directly test-only path above - but the attribute lives in the
/// declaring file, not this one, so this file's own text carries no trace
/// of it. Keyed by (declaring file's module directory, declared name)
/// rather than by name alone: more than one directory in this tree declares
/// a same-named `test_support` child with different gating, and only the
/// full pair tells those apart. `#[cfg(any(test, feature = "..."))]` is
/// deliberately not collected here either, for the same reason
/// `strip_cfg_test_blocks` leaves it alone: it can gate real production
/// reachability too.
fn is_declared_test_only(file: &Path, declared: &BTreeSet<(PathBuf, String)>) -> bool {
    let Some(stem) = file.file_stem().and_then(|stem| stem.to_str()) else {
        return false;
    };
    if stem == "mod" {
        let Some(parent) = file.parent() else {
            return false;
        };
        let Some(name) = parent.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        let Some(grandparent) = parent.parent() else {
            return false;
        };
        declared.contains(&(grandparent.to_path_buf(), name.to_string()))
    } else {
        let Some(parent) = file.parent() else {
            return false;
        };
        declared.contains(&(parent.to_path_buf(), stem.to_string()))
    }
}

fn cfg_test_only_child_modules(files: &[PathBuf]) -> BTreeSet<(PathBuf, String)> {
    let mut declared = BTreeSet::new();
    for file in files {
        let contents = fs::read_to_string(file)
            .unwrap_or_else(|error| panic!("read {}: {error}", file.display()));
        let module_dir = module_declaration_dir(file);
        let mut pending = false;
        for line in contents.lines() {
            let trimmed = line.trim();
            if is_pure_test_cfg_attribute(trimmed) {
                pending = true;
                continue;
            }
            if !pending {
                continue;
            }
            if trimmed.starts_with('#') || trimmed.starts_with("//") {
                continue;
            }
            pending = false;
            if let Some(name) = bare_mod_declaration_name(trimmed) {
                declared.insert((module_dir.clone(), name.to_string()));
            }
        }
    }
    declared
}

/// Where `file`'s own `mod child;` declarations resolve on disk: alongside
/// it for a `name.rs` file, or in its own directory for a `mod.rs` file.
fn module_declaration_dir(file: &Path) -> PathBuf {
    let stem = file
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    let parent = file.parent().unwrap_or(file);
    if stem == "mod" {
        parent.to_path_buf()
    } else {
        parent.join(stem)
    }
}

fn bare_mod_declaration_name(trimmed: &str) -> Option<&str> {
    let mut rest = trimmed;
    if let Some(after_paren) = rest.strip_prefix("pub(") {
        let close = after_paren.find(')')?;
        rest = after_paren[close + 1..].trim_start();
    } else if let Some(after_pub) = rest.strip_prefix("pub ") {
        rest = after_pub.trim_start();
    }
    let rest = rest.strip_prefix("mod ")?.trim();
    let name = rest.strip_suffix(';')?.trim();
    let is_plain_ident = !name.is_empty()
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_');
    is_plain_ident.then_some(name)
}

/// `#[cfg(test)]` and `#[cfg(all(test, ...))]` both require `test` on their
/// own, so both are unconditionally test-only regardless of any other
/// condition alongside it. `#[cfg(any(test, ...))]` is different and
/// deliberately excluded: an `any` can be true through its other branch
/// alone, so it can gate real production reachability too (see
/// `strip_cfg_test_blocks` and `cfg_test_only_child_modules`, the two
/// callers that rely on this distinction).
fn is_pure_test_cfg_attribute(trimmed: &str) -> bool {
    trimmed.starts_with("#[cfg(test)]") || trimmed.starts_with("#[cfg(all(test,")
}

/// Drops every unconditionally test-only (`is_pure_test_cfg_attribute`)
/// gated item from `contents`, block or bare statement, so a dev-only crate
/// used solely there is invisible to the dependency scan below. Deliberately
/// narrower than `#[cfg(any(test, feature = "daemon-runtime"))]` and
/// similar: those also gate production reachability under a real feature,
/// so stripping them would risk hiding a genuine production dependency
/// instead of a dev-only one.
fn strip_cfg_test_blocks(contents: &str) -> String {
    let mut kept = String::with_capacity(contents.len());
    let mut depth: i32 = 0;
    let mut skip_from_depth: Option<i32> = None;
    let mut pending_test_attribute = false;

    for line in contents.lines() {
        let trimmed = line.trim_start();
        // Brace-tracked, not a plain substring cut, so production code that
        // follows a gated block in the same file still gets scanned. A
        // `#[cfg(test)]` item can carry further attributes or line comments
        // before its own line (e.g. a trailing `#[allow(..)]`), and its own
        // opening `{` is not guaranteed to share a line with the item
        // (`mod tests\n{` is valid Rust; nothing here enforces rustfmt's
        // same-line style). Keep waiting through all of that: a line ending
        // in neither `{` nor `;` cannot be the end of the gated item, since
        // every legal item is one or the other, so it is safe to hold off
        // resolving until one appears. Only resolving on that concrete
        // character - not on the first non-attribute line, brace or not -
        // also keeps `skip_from_depth`'s later `depth <= start_depth` check
        // correct: it only ever gets set on the very line whose own `{` is
        // about to raise `depth` past `start_depth`, so that check can never
        // fire back to `None` on the same line it just opened.
        let mut exclude_this_line = skip_from_depth.is_some();
        if skip_from_depth.is_none() {
            if is_pure_test_cfg_attribute(trimmed) {
                pending_test_attribute = true;
                exclude_this_line = true;
            } else if pending_test_attribute {
                exclude_this_line = true;
                if trimmed.starts_with('#') || trimmed.starts_with("//") {
                    // another attribute or a comment on the same gated item;
                    // keep waiting for the item itself
                } else if line.contains('{') {
                    skip_from_depth = Some(depth);
                    pending_test_attribute = false;
                } else if trimmed.ends_with(';') {
                    // a bare statement (`mod tests;`, `use foo::Bar;`) with
                    // nothing to skip beyond this already-excluded line
                    pending_test_attribute = false;
                }
                // otherwise the item's declaration continues past this
                // line with neither terminator yet (e.g. a multi-line `fn`
                // signature) - keep waiting
            }
        }

        if !exclude_this_line {
            kept.push_str(line);
            kept.push('\n');
        }
        for character in line.chars() {
            match character {
                '{' => depth += 1,
                '}' => depth -= 1,
                _ => {}
            }
        }
        if skip_from_depth.is_some_and(|start_depth| depth <= start_depth) {
            skip_from_depth = None;
        }
    }

    kept
}

/// Every occurrence of the literal text `feature = "..."` anywhere in
/// `contents`, deliberately unfiltered by test-vs-production placement (see
/// the call site for why) and by attribute context: in practice this text
/// only ever appears inside a `#[cfg(...)]` / `#[cfg_attr(...)]` attribute,
/// so a plain substring scan already gets every real feature check without
/// needing to parse the attribute around it.
fn used_cfg_feature_names(contents: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let needle = "feature = \"";
    for line in contents.lines() {
        let mut rest = line;
        while let Some(start) = rest.find(needle) {
            let after = &rest[start + needle.len()..];
            let Some(end) = after.find('"') else { break };
            names.insert(after[..end].to_string());
            rest = &after[end + 1..];
        }
    }
    names
}

/// Every crate-looking identifier immediately before a `::`, whether it
/// comes from a `use <crate>::...` import (which this also covers - no
/// separate `use`-only pass is needed, since `use foo::bar;` contains the
/// same literal `foo::` this already finds) or a fully-qualified call with
/// no `use` at all (`serde_json::to_value(..)`, `tracing::warn!(..)`). This
/// repository's `absolute-paths-max-segments = 2` clippy config allows that
/// two-segment shape outright, so a crate used only that way carries no
/// matching `use` line anywhere to find. Over-collects internal path
/// segments too (the `bar` in `foo::bar::Baz`, or a type before `::method`,
/// filtered to a lowercase-or-`_` leading character to drop most of the
/// latter), but the caller only acts on a name that already matches a real
/// dependency in one of the two manifests, so that noise never surfaces.
fn used_crate_idents(contents: &str) -> BTreeSet<String> {
    let mut idents = BTreeSet::new();
    for line in contents.lines() {
        for (position, _) in line.match_indices("::") {
            let prefix = &line[..position];
            let ident_start = prefix
                .rfind(|character: char| !(character.is_ascii_alphanumeric() || character == '_'))
                .map_or(0, |index| index + 1);
            let ident = &prefix[ident_start..];
            let looks_like_a_crate_name = ident
                .chars()
                .next()
                .is_some_and(|character| character.is_ascii_lowercase() || character == '_');
            if looks_like_a_crate_name
                && !matches!(ident, "crate" | "self" | "super" | "std" | "core" | "alloc")
            {
                idents.insert(ident.to_string());
            }
        }
    }
    idents
}

fn manifest_dependency_idents(manifest: &str) -> BTreeSet<String> {
    manifest_section_keys(manifest, is_dependency_table_header)
        .into_iter()
        .map(|key| key.replace('-', "_"))
        .collect()
}

fn manifest_feature_names(manifest: &str) -> BTreeSet<String> {
    manifest_section_keys(manifest, |header| header == "[features]")
}

fn is_dependency_table_header(header: &str) -> bool {
    header == "[dependencies]"
        || header == "[dev-dependencies]"
        || (header.starts_with("[target.") && header.ends_with(".dependencies]"))
}

/// Plain per-line scan rather than a TOML parser: this crate stays
/// dependency-free on purpose, and every dependency and feature entry in
/// both manifests is already a single `key = ...` line, even when its value
/// spans further lines as a multi-line array or inline table.
fn manifest_section_keys(
    manifest: &str,
    is_wanted_header: impl Fn(&str) -> bool,
) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let mut in_wanted_section = false;
    for line in manifest.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_wanted_section = is_wanted_header(trimmed);
            continue;
        }
        if !in_wanted_section || trimmed.starts_with('#') {
            continue;
        }
        let Some(equals) = line.find('=') else {
            continue;
        };
        let key = line[..equals].trim().trim_matches(['"', '\'']);
        let is_plain_key = !key.is_empty()
            && key.chars().all(|character| {
                character.is_ascii_alphanumeric() || character == '-' || character == '_'
            });
        if is_plain_key {
            keys.insert(key.to_string());
        }
    }
    keys
}

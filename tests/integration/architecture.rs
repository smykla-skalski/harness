use std::fs;
use std::path::Path;

#[test]
fn new_domain_roots_exist() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "ARCHITECTURE.md",
        "src/app",
        "src/run",
        "src/authoring",
        "src/observe",
        "src/setup",
        "src/platform",
        "src/infra",
        "src/hooks",
    ] {
        assert!(root.join(path).exists(), "missing expected path: {path}");
    }
}

#[test]
fn legacy_scatter_roots_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "src/commands",
        "src/workflow",
        "src/context",
        "src/run_services",
        "src/prepared_suite",
        "src/bootstrap.rs",
        "src/authoring_validate.rs",
        "src/cluster",
        "src/compose",
        "src/exec",
        "src/io",
        "src/runtime.rs",
    ] {
        assert!(
            !root.join(path).exists(),
            "legacy layout path should not exist anymore: {path}"
        );
    }
}

#[test]
fn kuma_contracts_are_isolated_to_block_namespace() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let src_root = root.join("src");
    let excluded = root.join("src/infra/blocks/kuma");
    let denylist = [
        "Kuma test harness",
        "~kuma",
        ".join(\"kuma\")",
        "`harness cluster`",
        "harness cluster ",
        "`harness token`",
        "harness token ",
        "`harness service`",
        "harness service ",
        "`harness api`",
        "harness api ",
        "`harness kumactl`",
        "harness kumactl ",
    ];

    let mut stack = vec![src_root];
    let mut hits = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(&path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.starts_with(&excluded) {
                continue;
            }
            if child.is_dir() {
                stack.push(child);
                continue;
            }
            if !matches_extension(&child) {
                continue;
            }
            let contents = fs::read_to_string(&child).unwrap();
            for needle in denylist {
                if contents.contains(needle) {
                    hits.push(format!(
                        "{} contains forbidden Kuma contract `{needle}`",
                        child.strip_prefix(root).unwrap().display()
                    ));
                }
            }
        }
    }

    assert!(
        hits.is_empty(),
        "found Kuma contract leaks outside src/infra/blocks/kuma:\n{}",
        hits.join("\n")
    );
}

fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("rs" | "snap" | "md")
    )
}

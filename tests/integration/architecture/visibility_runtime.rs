use std::fs;
use std::path::Path;

mod core;
mod hooks;
mod infra;
mod kuma;
mod observe;
mod platform;
mod run;
mod setup;

fn assert_split_modules_exist(root: &Path, paths: &[&str], message: &str) {
    for path in paths {
        assert!(root.join(path).exists(), "{message}: {path}");
    }
}

#[test]
fn app_cli_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cli = fs::read_to_string(root.join("src/app/cli.rs")).unwrap();

    for needle in [
        "fn all_expected_subcommands_registered(",
        "fn parse_init_command(",
        "mod tests {",
    ] {
        assert!(
            !cli.contains(needle),
            "src/app/cli.rs should stay focused on production CLI transport instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/app/cli/tests.rs").exists(),
        "app cli split test module should exist"
    );
}

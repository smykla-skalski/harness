use std::fs;
use std::path::Path;

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

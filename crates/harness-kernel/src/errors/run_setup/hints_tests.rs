use super::super::RunSetupError;

/// Scans the source rather than the variants: a hint is only wrong once someone
/// writes it, and a test that lists variants silently stops covering the one
/// nobody remembered to add. The needle is assembled so this file cannot match
/// itself while still naming what it looks for.
#[test]
fn no_hint_names_a_command_this_crate_cannot_verify() {
    let source = include_str!("hints.rs");
    let quoted_command = ["`", "harness", " "].concat();

    let offenders: Vec<&str> = source
        .lines()
        .filter(|line| line.contains(&quoted_command))
        .collect();

    assert!(
        offenders.is_empty(),
        "hints must describe state instead of naming a command this crate cannot \
         confirm the binaries accept: {offenders:?}"
    );
}

#[test]
fn state_describing_hints_survive() {
    let unreadable = RunSetupError::MissingRunStatus;
    assert!(
        unreadable
            .hint()
            .is_some_and(|hint| hint.contains("run directory")),
        "an error about unreadable state should still say where to look"
    );
}

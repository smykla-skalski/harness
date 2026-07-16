use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use crate::errors::CliError;

use super::{ScriptedSystemdState, UpgradeFixture, success_output};

const CONFLICTING_SERVICE: &str = "other-harness.service";

pub(super) fn run(
    args: &[String],
    fixture: &UpgradeFixture,
    state: &mut ScriptedSystemdState,
) -> Option<Result<RemoteSystemdCommandOutput, CliError>> {
    match args.first().map(String::as_str) {
        Some("list-unit-files") => {
            state.inventory_passes += 1;
            Some(Ok(success_output(list_unit_files(fixture, state))))
        }
        Some("list-units") => Some(Ok(success_output(list_units(fixture, state)))),
        Some("show") if args.iter().any(|arg| arg == "--property=Id") => {
            Some(Ok(success_output(show_service(args, fixture))))
        }
        _ => None,
    }
}

fn list_unit_files(fixture: &UpgradeFixture, state: &ScriptedSystemdState) -> String {
    let mut output = format!("{}.service enabled enabled\n", fixture.operation.unit);
    if conflict_is_visible(state) {
        output.push_str(CONFLICTING_SERVICE);
        output.push_str(" enabled enabled\n");
    }
    output
}

fn list_units(fixture: &UpgradeFixture, state: &ScriptedSystemdState) -> String {
    let mut output = format!(
        "{}.service loaded active running Harness remote daemon\n",
        fixture.operation.unit
    );
    if conflict_is_visible(state) {
        output.push_str(CONFLICTING_SERVICE);
        output.push_str(" loaded active running Conflicting harness daemon\n");
    }
    output
}

fn conflict_is_visible(state: &ScriptedSystemdState) -> bool {
    state
        .inventory_conflict_from_pass
        .is_some_and(|pass| state.inventory_passes >= pass)
}

fn show_service(args: &[String], fixture: &UpgradeFixture) -> String {
    let queried = args.last().map(String::as_str).unwrap_or_default();
    let target = format!("{}.service", fixture.operation.unit);
    let fragment = if queried == target {
        fixture.unit.display().to_string()
    } else {
        "/etc/systemd/system/other-harness.service".to_string()
    };
    format!(
        "Id={queried}\nNames={queried}\nLoadState=loaded\nFragmentPath={fragment}\nDropInPaths=\nExecStart={{ path={} ; argv[]={} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }}\n",
        fixture.binary.display(),
        fixture.binary.display()
    )
}

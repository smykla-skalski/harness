use crate::daemon::transport::remote_systemd_upgrade_lifecycle::RemoteSystemdOperationPlan;

pub(super) fn is_timer_command(args: &[String]) -> bool {
    args.last()
        .is_some_and(|value| value.ends_with("-harness-recovery.timer"))
}

pub(super) fn show(
    plan: &RemoteSystemdOperationPlan,
    name: &str,
    recovery_timer_enabled: bool,
) -> Option<String> {
    let service_name = format!("{}-harness-recovery.service", plan.unit);
    if name == service_name {
        return Some(format!(
            "LoadState=loaded\nFragmentPath={}\nDropInPaths=\nActiveState=inactive\nUnitFileState=static\n",
            plan.unit_path.with_file_name(service_name).display()
        ));
    }
    let timer_name = format!("{}-harness-recovery.timer", plan.unit);
    if name != timer_name {
        return None;
    }
    let active = if recovery_timer_enabled {
        "active"
    } else {
        "inactive"
    };
    let enabled = if recovery_timer_enabled {
        "enabled"
    } else {
        "disabled"
    };
    Some(format!(
        "LoadState=loaded\nFragmentPath={}\nDropInPaths=\nActiveState={active}\nUnitFileState={enabled}\n",
        plan.unit_path.with_file_name(timer_name).display()
    ))
}

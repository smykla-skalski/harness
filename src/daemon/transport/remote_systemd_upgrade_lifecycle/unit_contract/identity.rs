use crate::errors::CliError;

use super::super::files::io_error;
use super::{require_effective_value, required_property};

const SYSTEMD_DYNAMIC_UID_MIN: u32 = 61_184;
const SYSTEMD_DYNAMIC_UID_MAX: u32 = 65_519;
const UNSET_ID: &str = "[not set]";

pub(super) fn require_effective_identity(stdout: &str) -> Result<(), CliError> {
    require_effective_value(stdout, "NeedDaemonReload", "no")?;
    require_effective_value(stdout, "DynamicUser", "yes")?;
    require_dynamic_user_and_group(stdout)?;
    require_dynamic_runtime_ids(stdout)?;
    require_effective_value(stdout, "KillMode", "control-group")
}

fn require_dynamic_user_and_group(stdout: &str) -> Result<(), CliError> {
    let user = required_property(stdout, "User")?;
    let group = required_property(stdout, "Group")?;
    if user.is_empty() || matches!(user, "root" | "0") {
        return Err(io_error(format!(
            "effective DynamicUser identity must be nonempty and unprivileged, found User={user}"
        )));
    }
    if group != user {
        return Err(io_error(format!(
            "effective DynamicUser identity requires equal User and Group, found User={user}, Group={group}"
        )));
    }
    Ok(())
}

fn require_dynamic_runtime_ids(stdout: &str) -> Result<(), CliError> {
    let main_pid = parse_u32_property(stdout, "MainPID")?;
    let uid = required_property(stdout, "UID")?;
    let gid = required_property(stdout, "GID")?;
    if main_pid == 0 {
        return require_unallocated_ids(uid, gid);
    }
    let uid = parse_u32_value("UID", uid)?;
    let gid = parse_u32_value("GID", gid)?;
    if uid != gid || !(SYSTEMD_DYNAMIC_UID_MIN..=SYSTEMD_DYNAMIC_UID_MAX).contains(&uid) {
        return Err(io_error(format!(
            "active DynamicUser identity requires equal UID and GID in {SYSTEMD_DYNAMIC_UID_MIN}..={SYSTEMD_DYNAMIC_UID_MAX}, found UID={uid}, GID={gid}"
        )));
    }
    Ok(())
}

fn require_unallocated_ids(uid: &str, gid: &str) -> Result<(), CliError> {
    if uid == UNSET_ID && gid == UNSET_ID {
        Ok(())
    } else {
        Err(io_error(format!(
            "inactive DynamicUser identity requires UID={UNSET_ID} and GID={UNSET_ID}, found UID={uid}, GID={gid}"
        )))
    }
}

fn parse_u32_property(stdout: &str, key: &str) -> Result<u32, CliError> {
    parse_u32_value(key, required_property(stdout, key)?)
}

fn parse_u32_value(key: &str, value: &str) -> Result<u32, CliError> {
    value
        .parse::<u32>()
        .map_err(|error| io_error(format!("parse effective systemd {key}={value}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::require_effective_identity;

    fn output(user: &str, group: &str, main_pid: u32, uid: &str, gid: &str) -> String {
        format!(
            "NeedDaemonReload=no\nDynamicUser=yes\nUser={user}\nGroup={group}\nMainPID={main_pid}\nUID={uid}\nGID={gid}\nKillMode=control-group\n"
        )
    }

    #[test]
    fn loaded_dynamic_user_names_are_accepted_before_allocation() {
        for user in ["harness-remote", "_du0123456789abcdef"] {
            require_effective_identity(&output(user, user, 0, "[not set]", "[not set]"))
                .expect("systemd-derived identity");
        }
    }

    #[test]
    fn active_dynamic_user_requires_the_systemd_dynamic_id_range() {
        require_effective_identity(&output(
            "harness-remote",
            "harness-remote",
            42,
            "62786",
            "62786",
        ))
        .expect("allocated dynamic identity");

        for (uid, gid) in [("0", "0"), ("62786", "62787"), ("1000", "1000")] {
            let error = require_effective_identity(&output(
                "harness-remote",
                "harness-remote",
                42,
                uid,
                gid,
            ))
            .expect_err("unsafe runtime identity must fail closed");
            assert!(error.to_string().contains("equal UID and GID"));
        }
    }

    #[test]
    fn stale_or_privileged_effective_identities_are_rejected() {
        let stale = output(
            "harness-remote",
            "harness-remote",
            0,
            "[not set]",
            "[not set]",
        )
        .replace("NeedDaemonReload=no", "NeedDaemonReload=yes");
        assert!(
            require_effective_identity(&stale)
                .expect_err("stale manager state")
                .to_string()
                .contains("NeedDaemonReload=no")
        );

        for (user, group) in [("", ""), ("root", "root"), ("harness-remote", "other")] {
            assert!(
                require_effective_identity(&output(user, group, 0, "[not set]", "[not set]"))
                    .is_err()
            );
        }
    }
}

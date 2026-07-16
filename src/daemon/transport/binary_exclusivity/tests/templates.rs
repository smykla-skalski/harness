use std::cell::RefCell;

use tempfile::tempdir;

use super::super::{RemoteSystemdCommandOutput, validate_exclusive_systemd_binary};
use super::{create_file, exec_record, success};
use crate::errors::CliError;

const TEMPLATE: &str = "worker@.service";
const TEMPLATE_FRAGMENT: &str = "/etc/systemd/system/worker@.service";

#[test]
fn inspects_template_through_two_synthetic_instances() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let queried = RefCell::new(Vec::new());
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => format!("{TEMPLATE} disabled enabled\n"),
            "list-units" => String::new(),
            "show" => {
                let name = args.last().expect("query name").clone();
                queried.borrow_mut().push(name.clone());
                template_show(&name, &target.display().to_string(), "", TEMPLATE_FRAGMENT)
            }
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error = validate_exclusive_systemd_binary("target", &target, &runner)
        .expect_err("template shares target binary");

    assert_eq!(
        queried.into_inner(),
        [
            "worker@harness-inventory-a.service".to_string(),
            "worker@harness-inventory-b.service".to_string()
        ]
    );
    assert!(error.to_string().contains(TEMPLATE));
}

#[test]
fn accepts_instance_dependent_argv_with_stable_executable() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let other = create_file(temp.path(), "other");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => format!("{TEMPLATE} disabled enabled\n"),
            "list-units" => String::new(),
            "show" => {
                let name = args.last().expect("query name");
                template_show(name, &other.display().to_string(), name, TEMPLATE_FRAGMENT)
            }
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    validate_exclusive_systemd_binary("target", &target, &runner)
        .expect("instance-varying argv does not change executable ownership");
}

#[test]
fn rejects_instance_dependent_template_executable_paths() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => format!("{TEMPLATE} disabled enabled\n"),
            "list-units" => String::new(),
            "show" => {
                let name = args.last().expect("query name");
                let executable = temp.path().join(name);
                template_show(
                    name,
                    &executable.display().to_string(),
                    "",
                    TEMPLATE_FRAGMENT,
                )
            }
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error = validate_exclusive_systemd_binary("target", &target, &runner)
        .expect_err("instance-dependent executable path");

    assert!(error.to_string().contains("instance-dependent template"));
}

#[test]
fn rejects_instance_dependent_template_sources() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let other = create_file(temp.path(), "other");
    for source_kind in ["fragment", "drop-in"] {
        let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            let stdout = match args[0].as_str() {
                "list-unit-files" => format!("{TEMPLATE} disabled enabled\n"),
                "list-units" => String::new(),
                "show" => {
                    let name = args.last().expect("query name");
                    let suffix = name
                        .strip_prefix("worker@harness-inventory-")
                        .and_then(|value| value.strip_suffix(".service"))
                        .expect("synthetic suffix");
                    let fragment = if source_kind == "fragment" {
                        format!("/etc/systemd/system/worker@{suffix}.service")
                    } else {
                        TEMPLATE_FRAGMENT.to_string()
                    };
                    let drop_ins = if source_kind == "drop-in" {
                        format!("/etc/systemd/system/worker@{suffix}.service.d/test.conf")
                    } else {
                        String::new()
                    };
                    template_show_with_drop_ins(
                        name,
                        &other.display().to_string(),
                        "",
                        &fragment,
                        &drop_ins,
                    )
                }
                command => panic!("unexpected command {command}"),
            };
            Ok(success(&stdout))
        };

        let error = validate_exclusive_systemd_binary("target", &target, &runner)
            .expect_err("instance-dependent template source");

        assert!(
            error.to_string().contains("instance-dependent template"),
            "source kind {source_kind} was not checked"
        );
    }
}

fn template_show(id: &str, executable: &str, argv: &str, fragment: &str) -> String {
    template_show_with_drop_ins(id, executable, argv, fragment, "")
}

fn template_show_with_drop_ins(
    id: &str,
    executable: &str,
    argv: &str,
    fragment: &str,
    drop_ins: &str,
) -> String {
    let argv = if argv.is_empty() { executable } else { argv };
    format!(
        "Id={id}\nNames={id}\nLoadState=loaded\nFragmentPath={fragment}\nDropInPaths={drop_ins}\nExecStart={}\n",
        exec_record(executable, argv)
    )
}

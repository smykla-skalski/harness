use std::cell::RefCell;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use tempfile::tempdir;

use super::inventory::{InventoryKind, parse_inventory};
use super::parser::{EXECUTABLE_PROPERTIES, parse_exec_start, parse_service_observation};
use super::{RemoteSystemdCommandOutput, validate_exclusive_systemd_binary};
use crate::errors::CliError;

#[path = "tests/search_path.rs"]
mod search_path;
#[path = "tests/templates.rs"]
mod templates;

#[test]
fn inventories_installed_loaded_and_alias_names_once() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let other = create_file(temp.path(), "other");
    let calls = RefCell::new(Vec::new());
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        calls.borrow_mut().push(args.to_vec());
        let stdout = match args[0].as_str() {
            "list-unit-files" => "target.service enabled enabled\nalias.service alias -\ndormant.service disabled enabled\n".to_string(),
            "list-units" => "target.service loaded active running Target\ntransient.service loaded inactive dead Transient\n".to_string(),
            "show" => match args.last().map(String::as_str) {
                Some("target.service" | "alias.service") => {
                    show("target.service", "alias.service target.service", &target)
                }
                Some("dormant.service") => show("dormant.service", "dormant.service", &other),
                Some("transient.service") => format!(
                    "Names=transient.service\nExecStart={}\nExecStart={}\nDropInPaths=\nId=transient.service\nFragmentPath=\nLoadState=loaded\n",
                    exec_record(&other.display().to_string(), &other.display().to_string()),
                    exec_record(
                        &other.display().to_string(),
                        &format!("{} second", other.display())
                    )
                ),
                name => panic!("unexpected show name {name:?}"),
            },
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    validate_exclusive_systemd_binary("target", &target, &runner).expect("exclusive");

    let calls = calls.into_inner();
    assert_eq!(calls.iter().filter(|args| args[0] == "show").count(), 4);
    assert_eq!(calls[0][0], "list-unit-files");
    assert_eq!(calls[1][0], "list-units");
}

#[test]
fn rejects_another_service_using_a_symlink_to_target() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let alias = temp.path().join("target-link");
    symlink(&target, &alias).expect("symlink");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show("other.service", "other.service", &alias),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary("target", &target, &runner).expect_err("shared binary");

    assert!(error.to_string().contains("shares target executable"));
}

#[test]
fn rejects_another_service_using_a_hard_link_to_target() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let alias = temp.path().join("target-hard-link");
    fs::hard_link(&target, &alias).expect("hard link");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show("other.service", "other.service", &alias),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary("target", &target, &runner).expect_err("shared inode");

    assert!(error.to_string().contains("shares target executable"));
}

#[test]
fn rejects_target_from_every_systemd_exec_phase() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    for property in EXECUTABLE_PROPERTIES {
        let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            let stdout = match args[0].as_str() {
                "list-unit-files" => "other.service enabled enabled\n".to_string(),
                "list-units" => String::new(),
                "show" => show_exec_property(
                    "other.service",
                    "other.service",
                    property,
                    &target.display().to_string(),
                ),
                command => panic!("unexpected command {command}"),
            };
            Ok(success(&stdout))
        };

        let error = validate_exclusive_systemd_binary("target", &target, &runner)
            .expect_err("shared executable in systemd command phase");

        assert!(
            error.to_string().contains("shares target executable"),
            "property {property} was not checked"
        );
    }
}

#[test]
fn rejects_non_service_units_using_target_executable() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    for (unit, property) in [
        ("other.socket", "ExecStopPre"),
        ("srv-data.mount", "ExecMount"),
        ("dev-sda.swap", "ExecActivate"),
    ] {
        let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            let stdout = match args[0].as_str() {
                "list-unit-files" => format!("{unit} enabled enabled\n"),
                "list-units" => String::new(),
                "show" => show_exec_property(unit, unit, property, &target.display().to_string()),
                command => panic!("unexpected command {command}"),
            };
            Ok(success(&stdout))
        };

        let error = validate_exclusive_systemd_binary("target", &target, &runner)
            .expect_err("non-service unit shares target executable");

        assert!(
            error.to_string().contains("shares target executable"),
            "unit {unit} was not checked"
        );
    }
}

#[test]
fn permits_an_unrelated_currently_missing_executable() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let missing = temp.path().join("missing");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "broken.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show("broken.service", "broken.service", &missing),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    validate_exclusive_systemd_binary("target", &target, &runner)
        .expect("missing unrelated executable is non-runnable");
}

#[test]
fn rejects_target_name_aliasing_another_canonical_id() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let other = create_file(temp.path(), "other");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "target.service alias -\n".to_string(),
            "list-units" => String::new(),
            "show" => show("owner.service", "owner.service target.service", &other),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error = validate_exclusive_systemd_binary("target", &target, &runner)
        .expect_err("identity conflict");

    assert!(error.to_string().contains("unexpected systemd Id"));
}

#[test]
fn parses_exec_records_with_opaque_shell_arguments() {
    let first = exec_record(
        "/bin/bash",
        "/bin/bash -c read args <&3; echo \"} { path=/not-a-record $args\"; exec /usr/bin/tool $args; exit 0",
    );
    let second = exec_record(
        "/usr/share/mdadm/mdcheck",
        "/usr/share/mdadm/mdcheck --duration ${MDADM_CHECK_DURATION}",
    );
    let first_path = parse_exec_start(&first).expect("first record");
    let second_path = parse_exec_start(&second).expect("second record");

    assert_eq!(first_path, [PathBuf::from("/bin/bash")]);
    assert_eq!(second_path, [PathBuf::from("/usr/share/mdadm/mdcheck")]);
}

#[test]
fn rejects_malformed_exec_records() {
    for value in [
        "{ path=/bin/one ; argv[]=/bin/one",
        "{ path=/bin/one ; path=/bin/two }",
        "{ argv[]=/bin/one }",
        "prefix { path=/bin/one }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 } trailing",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 } { path=/bin/two ; argv[]=/bin/two ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=maybe ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=oops ; code=(null) ; status=0/0 }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=n/a ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }",
        "{ path=/bin/one ; argv[]=/bin/one ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=success }",
        "{ path=/bin/one ; argv[]=/bin/one ; argv[]=ambiguous ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }",
    ] {
        assert!(parse_exec_start(value).is_err(), "accepted {value}");
    }
}

#[test]
fn preserves_raw_exec_path_characters() {
    for path in [
        "/opt/harness binaries/harness",
        r"/opt/harness\binary",
        r#"/opt/harness\"binary"#,
    ] {
        let record = exec_record(path, path);

        assert_eq!(
            parse_exec_start(&record).expect("raw path"),
            [PathBuf::from(path)]
        );
    }
}

#[test]
fn show_rejects_duplicate_required_unknown_and_invalid_masked_properties() {
    let duplicate = "Id=a.service\nNames=a.service\nLoadState=loaded\nFragmentPath=/a\nDropInPaths=\nExecStart=\nId=a.service\n";
    let unknown = "Id=a.service\nNames=a.service\nLoadState=loaded\nFragmentPath=/a\nDropInPaths=\nExecStart=\nUnitFileState=enabled\n";
    let masked = "Id=a.service\nNames=a.service\nLoadState=masked\nFragmentPath=/dev/null\nDropInPaths=\nExecStart=\n";

    assert!(parse_service_observation(duplicate).is_err());
    assert!(parse_service_observation(unknown).is_err());
    assert!(parse_service_observation(masked).is_err());
}

#[test]
fn loaded_service_without_exec_start_has_no_executable() {
    let omitted =
        "Id=a.service\nNames=a.service\nLoadState=loaded\nFragmentPath=/a\nDropInPaths=\n";
    let empty = format!("{omitted}ExecStart=\n");

    for stdout in [omitted, &empty] {
        let service = parse_service_observation(stdout).expect("valid service without ExecStart");

        assert!(service.executables.is_empty());
    }
}

#[test]
fn parses_shell_escaped_systemd_names() {
    let stdout = r#"Id=systemd-fsck@dev-disk-by\x2duuid.service
Names="systemd-fsck@dev-disk-by\\x2duuid.service"
LoadState=loaded
FragmentPath=/usr/lib/systemd/system/systemd-fsck@.service
DropInPaths=
"#;

    let service = parse_service_observation(stdout).expect("escaped systemd name");

    assert!(service.names.contains(&service.id));
}

#[test]
fn loaded_service_accepts_repeated_exec_start_properties() {
    let first = exec_record("/bin/one", "/bin/one first");
    let second = exec_record("/bin/two", "/bin/two second; still-second");
    let stdout = format!(
        "Id=a.service\nNames=a.service\nLoadState=loaded\nFragmentPath=/a\nDropInPaths=\nExecStart={first}\nExecStart={second}\n"
    );

    let service = parse_service_observation(&stdout).expect("repeated ExecStart properties");

    assert_eq!(
        service.executables,
        [PathBuf::from("/bin/one"), PathBuf::from("/bin/two")]
    );
}

#[test]
fn loaded_service_rejects_empty_exec_start_mixed_with_commands() {
    let record = exec_record("/bin/one", "/bin/one");
    for empty in ["", "   "] {
        let stdout = format!(
            "Id=a.service\nNames=a.service\nLoadState=loaded\nFragmentPath=/a\nDropInPaths=\nExecStart={empty}\nExecStart={record}\n"
        );

        assert!(parse_service_observation(&stdout).is_err());
    }
}

#[test]
fn accepts_only_proven_non_runnable_missing_or_masked_units() {
    let temp = tempdir().expect("tempdir");
    let mask = temp.path().join("masked.service");
    symlink("/dev/null", &mask).expect("mask symlink");
    let missing = "Id=missing.service\nNames=missing.service\nLoadState=not-found\nFragmentPath=\nDropInPaths=\n";
    let masked = format!(
        "Id=masked.service\nNames=masked.service\nLoadState=masked\nFragmentPath={}\nDropInPaths=\n",
        mask.display()
    );
    let inconsistent_missing = "Id=missing.service\nNames=missing.service\nLoadState=not-found\nFragmentPath=/etc/systemd/system/missing.service\nDropInPaths=\nExecStart=\n";

    assert!(parse_service_observation(missing).is_ok());
    assert!(parse_service_observation(&masked).is_ok());
    assert!(parse_service_observation(inconsistent_missing).is_err());
}

#[test]
fn inventory_rejects_truncated_and_invalid_unit_rows() {
    assert!(parse_inventory("lonely.service\n", InventoryKind::UnitFiles).is_err());
    assert!(
        parse_inventory(
            "nightly.timer loaded active waiting Nightly\n",
            InventoryKind::LoadedUnits,
        )
        .is_ok()
    );
    assert!(
        parse_inventory(
            "not-a-unit.invalid loaded active running Nope\n",
            InventoryKind::LoadedUnits,
        )
        .is_err()
    );
}

#[test]
fn rejects_nonzero_inventory_command() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 1,
            stdout: String::new(),
            stderr: "manager unavailable".to_string(),
        })
    };

    let error =
        validate_exclusive_systemd_binary("target", &target, &runner).expect_err("command failure");

    assert!(error.to_string().contains("manager unavailable"));
}

fn create_file(parent: &Path, name: &str) -> PathBuf {
    let path = parent.join(name);
    fs::write(&path, name).expect("write executable fixture");
    path
}

fn show(id: &str, names: &str, executable: &Path) -> String {
    show_exec(id, names, &executable.display().to_string(), "")
}

fn show_exec(id: &str, names: &str, executable: &str, extra_properties: &str) -> String {
    show_exec_from_fragment(
        id,
        names,
        executable,
        extra_properties,
        &format!("/etc/systemd/system/{id}"),
    )
}

fn show_exec_from_fragment(
    id: &str,
    names: &str,
    executable: &str,
    extra_properties: &str,
    fragment_path: &str,
) -> String {
    format!(
        "Id={id}\nNames={names}\nLoadState=loaded\nFragmentPath={fragment_path}\nDropInPaths=\n{extra_properties}ExecStart={}\n",
        exec_record(executable, executable)
    )
}

fn show_exec_property(id: &str, names: &str, property: &str, executable: &str) -> String {
    format!(
        "Id={id}\nNames={names}\nLoadState=loaded\nFragmentPath=/etc/systemd/system/{id}\nDropInPaths=\n{property}={}\n",
        exec_record(executable, executable)
    )
}

fn exec_record(path: &str, argv: &str) -> String {
    format!(
        "{{ path={path} ; argv[]={argv} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }}"
    )
}

fn success(stdout: &str) -> RemoteSystemdCommandOutput {
    RemoteSystemdCommandOutput {
        exit_code: 0,
        stdout: stdout.to_string(),
        stderr: String::new(),
    }
}

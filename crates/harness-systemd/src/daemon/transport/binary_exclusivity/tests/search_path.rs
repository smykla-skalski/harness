use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

use tempfile::tempdir;

use super::super::parser::parse_colon_search_path;
use super::super::{
    RemoteSystemdCommandOutput, inventory_error, systemd_manager_version,
    validate_exclusive_systemd_binary, validate_exclusive_systemd_binary_with_search_path,
};
use super::{create_file, show_exec, success};
use crate::errors::CliError;

#[test]
fn permits_unrelated_simple_executable_from_compiled_search_path() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let search = temp.path().join("bin");
    fs::create_dir(&search).expect("search directory");
    create_file(&search, "systemctl");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec("other.service", "other.service", "systemctl", ""),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
        Ok(vec![search.clone()])
    })
    .expect("unrelated simple executable");
}

#[test]
fn rejects_simple_executable_resolving_to_target() {
    let temp = tempdir().expect("tempdir");
    let search = temp.path().join("bin");
    fs::create_dir(&search).expect("search directory");
    let target = create_file(&search, "harness");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec("other.service", "other.service", "harness", ""),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
            Ok(vec![search.clone()])
        })
        .expect_err("relative target executable");

    assert!(error.to_string().contains("shares target executable"));
}

#[test]
fn scans_every_compiled_search_directory_for_target_aliases() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let first = temp.path().join("first");
    let second = temp.path().join("second");
    fs::create_dir(&first).expect("first directory");
    fs::create_dir(&second).expect("second directory");
    create_file(&first, "runner");
    fs::hard_link(&target, second.join("runner")).expect("target alias");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec("other.service", "other.service", "runner", ""),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
            Ok(vec![first.clone(), second.clone()])
        })
        .expect_err("later search path aliases target");

    assert!(error.to_string().contains("shares target executable"));
}

#[test]
fn uses_unit_exec_search_path_without_consulting_compiled_defaults() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let search = temp.path().join("custom");
    fs::create_dir(&search).expect("custom search directory");
    symlink(&target, search.join("runner")).expect("target alias");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec(
                "other.service",
                "other.service",
                "runner",
                &format!("ExecSearchPath={}\n", search.display()),
            ),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
            panic!("compiled defaults must not be consulted")
        })
        .expect_err("custom path aliases target");

    assert!(error.to_string().contains("shares target executable"));
}

#[test]
fn fails_closed_when_compiled_search_path_is_unavailable() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec("other.service", "other.service", "runner", ""),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
            Err(inventory_error("compiled path unavailable"))
        })
        .expect_err("missing compiled path");

    assert!(error.to_string().contains("compiled path unavailable"));
}

#[test]
fn alternate_mount_namespaces_fail_closed() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let other = create_file(temp.path(), "other");
    for (property, value) in [
        ("RootDirectory", "/srv/chroot"),
        ("RootImage", "/srv/root.raw"),
        ("RootMStack", "/srv/root.mstack"),
        ("BindPaths", "/srv/source:/usr/local/bin/harness"),
        ("BindReadOnlyPaths", "/srv/source:/usr/local/bin/harness"),
        ("ExtensionDirectories", "/srv/extension"),
        ("ExtensionImages", "/srv/extension.raw"),
        ("MountImages", "/srv/image.raw:/usr"),
        ("TemporaryFileSystem", "/usr:ro"),
    ] {
        let extra_property = format!("{property}={value}\n");
        let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            let stdout = match args[0].as_str() {
                "list-unit-files" => "other.service enabled enabled\n".to_string(),
                "list-units" => String::new(),
                "show" => {
                    assert!(args.contains(&format!("--property={property}")));
                    show_exec(
                        "other.service",
                        "other.service",
                        &other.display().to_string(),
                        &extra_property,
                    )
                }
                command => panic!("unexpected command {command}"),
            };
            Ok(success(&stdout))
        };

        let error = validate_exclusive_systemd_binary("target", &target, &runner)
            .expect_err("alternate mount namespace is not host-resolvable");

        assert!(
            error.to_string().contains("alternate mount namespace"),
            "property {property} was not checked"
        );
    }
}

#[test]
fn private_tmp_executable_path_fails_closed() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec(
                "other.service",
                "other.service",
                "/tmp/runner",
                "PrivateTmp=yes\n",
            ),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error = validate_exclusive_systemd_binary("target", &target, &runner)
        .expect_err("private temporary executable is not host-resolvable");

    assert!(error.to_string().contains("inside PrivateTmp"));
}

#[test]
fn private_tmp_exec_search_path_fails_closed() {
    let temp = tempdir().expect("tempdir");
    let target = create_file(temp.path(), "target");
    let runner = |args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        let stdout = match args[0].as_str() {
            "list-unit-files" => "other.service enabled enabled\n".to_string(),
            "list-units" => String::new(),
            "show" => show_exec(
                "other.service",
                "other.service",
                "runner",
                "ExecSearchPath=/tmp\nPrivateTmp=yes\n",
            ),
            command => panic!("unexpected command {command}"),
        };
        Ok(success(&stdout))
    };

    let error =
        validate_exclusive_systemd_binary_with_search_path("target", &target, &runner, &|| {
            panic!("compiled defaults must not be consulted")
        })
        .expect_err("private temporary search path is not host-resolvable");

    assert!(error.to_string().contains("inside PrivateTmp"));
}

#[test]
fn validates_colon_separated_compiled_search_path() {
    assert_eq!(
        parse_colon_search_path("/usr/local/bin:/usr/bin", "default path")
            .expect("compiled search path"),
        [PathBuf::from("/usr/local/bin"), PathBuf::from("/usr/bin")]
    );
    for value in ["", ":/usr/bin", "/usr/bin:", "relative:/usr/bin"] {
        assert!(
            parse_colon_search_path(value, "default path").is_err(),
            "accepted {value:?}"
        );
    }
}

#[test]
fn parses_manager_version_output_strictly() {
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        Ok(success("Version=255.4-1ubuntu8.16\n"))
    };

    assert_eq!(
        systemd_manager_version(&runner).expect("manager version"),
        "255.4-1ubuntu8.16"
    );

    for stdout in [
        "",
        "Version=\n",
        "Version=255\nVersion=256\n",
        "Other=255\n",
    ] {
        let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            Ok(success(stdout))
        };

        assert!(systemd_manager_version(&runner).is_err());
    }
}

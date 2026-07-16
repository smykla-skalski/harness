use super::*;

#[test]
fn loaded_storage_and_environment_must_match_managed_source() {
    for (property, replacement) in [
        ("StateDirectory=harness-remote", "StateDirectory=stale-data"),
        ("StateDirectoryMode=0700", "StateDirectoryMode=0755"),
        (
            "XDG_DATA_HOME=/var/lib/harness-remote",
            "XDG_DATA_HOME=/var/lib/stale-data",
        ),
        (
            "HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote",
            "HARNESS_DAEMON_DATA_HOME=%S/harness-remote",
        ),
        (
            "HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote",
            "HARNESS_DAEMON_DATA_HOME=/var/lib/private/harness-remote",
        ),
    ] {
        let fixture = ContractFixture::new();
        let error = fixture
            .validate_with(&fixture.effective_output().replace(property, replacement))
            .expect_err("stale loaded storage contract must fail closed");
        assert!(error.to_string().contains(property));
    }
}

#[test]
fn source_user_and_protected_unset_are_rejected() {
    let user_fixture = ContractFixture::new();
    user_fixture
        .rewrite_unit(|contents| contents.replace("DynamicUser=yes", "User=root\nDynamicUser=yes"));
    let user_error = user_fixture
        .validate_with(&user_fixture.effective_output())
        .expect_err("explicit root user must fail closed");
    assert!(user_error.to_string().contains("must not define User"));

    for protected_name in ["XDG_DATA_HOME", "STATE_DIRECTORY"] {
        let unset_fixture = ContractFixture::new();
        unset_fixture.rewrite_unit(|contents| {
            contents.replace(
                "DynamicUser=yes",
                &format!("UnsetEnvironment={protected_name}\nDynamicUser=yes"),
            )
        });
        let unset_error = unset_fixture
            .validate_with(&unset_fixture.effective_output())
            .expect_err("protected unset must fail closed");
        assert!(
            unset_error
                .to_string()
                .contains("must not unset protected variable")
        );
    }
}

#[test]
fn source_environment_cannot_spoof_manager_state_directory() {
    let unit_fixture = ContractFixture::new();
    unit_fixture.rewrite_unit(|contents| {
        contents.replace(
            "ExecStart=",
            "Environment=STATE_DIRECTORY=/var/lib/harness-remote\nExecStart=",
        )
    });
    let unit_error = validate_managed_unit_contract(&unit_fixture.plan, &|_| {
        panic!("source rejection must happen before effective inspection")
    })
    .expect_err("explicit STATE_DIRECTORY must fail closed");
    assert!(unit_error.to_string().contains("manager-owned variable"));

    let file_fixture = ContractFixture::new();
    fs::write(
        &file_fixture.plan.environment_path,
        "STATE_DIRECTORY=/var/lib/harness-remote\n",
    )
    .expect("write spoofed manager environment");
    let file_error = validate_managed_unit_contract(&file_fixture.plan, &|_| {
        panic!("environment rejection must happen before effective inspection")
    })
    .expect_err("environment-file STATE_DIRECTORY must fail closed");
    assert!(
        file_error
            .to_string()
            .contains("protected variable STATE_DIRECTORY")
    );
}

#[test]
fn effective_kill_mode_and_protected_environment_are_required() {
    let kill_fixture = ContractFixture::new();
    let kill_output = kill_fixture
        .effective_output()
        .replace("KillMode=control-group", "KillMode=process");
    let kill_error = kill_fixture
        .validate_with(&kill_output)
        .expect_err("unsafe kill mode must fail closed");
    assert!(kill_error.to_string().contains("KillMode=control-group"));

    let env_fixture = ContractFixture::new();
    let env_output = env_fixture
        .effective_output()
        .replace(" XDG_DATA_HOME=/var/lib/harness-remote", "");
    let env_error = env_fixture
        .validate_with(&env_output)
        .expect_err("missing protected environment must fail closed");
    assert!(
        env_error
            .to_string()
            .contains("must define XDG_DATA_HOME exactly once")
    );

    let duplicate_output = env_fixture.effective_output().replace(
        "HARNESS_DAEMON_OWNERSHIP=external",
        "HARNESS_DAEMON_DATA_HOME=/var/lib/harness-remote HARNESS_DAEMON_OWNERSHIP=external",
    );
    let duplicate_error = env_fixture
        .validate_with(&duplicate_output)
        .expect_err("duplicate protected environment must fail closed");
    assert!(
        duplicate_error
            .to_string()
            .contains("must define HARNESS_DAEMON_DATA_HOME exactly once")
    );
}

#[test]
fn effective_environment_cannot_spoof_or_remove_manager_state_directory() {
    let fixture = ContractFixture::new();
    let spoofed = fixture.effective_output().replace(
        " HARNESS_DAEMON_OWNERSHIP=external",
        " STATE_DIRECTORY=/var/lib/harness-remote HARNESS_DAEMON_OWNERSHIP=external",
    );
    let spoofed_error = fixture
        .validate_with(&spoofed)
        .expect_err("effective STATE_DIRECTORY override must fail closed");
    assert!(spoofed_error.to_string().contains("manager-owned variable"));

    let removed = fixture.effective_output().replace(
        "UnsetEnvironment=\n",
        "UnsetEnvironment=RUST_BACKTRACE STATE_DIRECTORY\n",
    );
    let removed_error = fixture
        .validate_with(&removed)
        .expect_err("effective STATE_DIRECTORY removal must fail closed");
    assert!(
        removed_error
            .to_string()
            .contains("must not unset protected variable")
    );
}

#[test]
fn omitted_empty_effective_auxiliary_properties_are_accepted() {
    let fixture = ContractFixture::new();
    let output = fixture
        .effective_output()
        .lines()
        .filter(|line| !line.starts_with("ExecStartPre=") && !line.starts_with("ExecStartPost="))
        .collect::<Vec<_>>()
        .join("\n");
    fixture
        .validate_with(&output)
        .expect("systemd may omit empty auxiliary properties");
}

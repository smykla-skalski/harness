use crate::daemon::transport::remote_systemd_start_permit::{
    install_runtime_start_permit, remove_stale_runtime_start_permit,
};

use super::*;

fn output_with_drop_in(fixture: &ContractFixture, path: &Path) -> String {
    fixture
        .effective_output()
        .replace("DropInPaths=", &format!("DropInPaths={}", path.display()))
}

#[test]
fn permitted_contract_requires_the_live_runtime_shadow_as_the_sole_drop_in() {
    let fixture = ContractFixture::new();
    install_inhibitor(&fixture.plan.unit_path).expect("install persistent inhibitor");
    let permit =
        install_runtime_start_permit(&fixture.plan.unit_path).expect("install runtime permit");
    let output = output_with_drop_in(&fixture, permit.path());

    validate_permitted_managed_unit_contract(&fixture.plan, &permit, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: output.clone(),
            stderr: String::new(),
        })
    })
    .expect("exact live permitted contract");

    let persistent = inhibitor_path(&fixture.plan.unit_path).expect("persistent inhibitor path");
    let wrong_output = output_with_drop_in(&fixture, &persistent);
    let error = validate_permitted_managed_unit_contract(&fixture.plan, &permit, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: wrong_output.clone(),
            stderr: String::new(),
        })
    })
    .expect_err("persistent path must be shadowed while the permit is live");
    assert!(error.to_string().contains("unexpected drop-ins"));

    permit.remove().expect("remove runtime permit");
}

#[test]
fn stale_runtime_shadow_never_validates_as_a_start_permit() {
    let fixture = ContractFixture::new();
    install_inhibitor(&fixture.plan.unit_path).expect("install persistent inhibitor");
    let mut permit =
        install_runtime_start_permit(&fixture.plan.unit_path).expect("install runtime permit");
    let path = permit.path().to_path_buf();
    let output = output_with_drop_in(&fixture, &path);
    permit
        .expire_liveness_for_tests()
        .expect("expire runtime permit liveness");

    let error = validate_permitted_managed_unit_contract(&fixture.plan, &permit, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: output.clone(),
            stderr: String::new(),
        })
    })
    .expect_err("stale runtime permit must fail closed");

    assert!(error.to_string().contains("is not live"));
    drop(permit);
    assert!(
        remove_stale_runtime_start_permit(&fixture.plan.unit_path)
            .expect("remove stale runtime permit")
    );
}

#[test]
fn permitted_contract_still_requires_the_persistent_inhibitor_on_disk() {
    let fixture = ContractFixture::new();
    let permit =
        install_runtime_start_permit(&fixture.plan.unit_path).expect("install runtime permit");
    let output = output_with_drop_in(&fixture, permit.path());

    let error = validate_permitted_managed_unit_contract(&fixture.plan, &permit, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: output.clone(),
            stderr: String::new(),
        })
    })
    .expect_err("missing persistent inhibitor must fail closed");

    assert!(
        error
            .to_string()
            .contains("persistent systemd inhibitor is not installed")
    );
    permit.remove().expect("remove runtime permit");
}

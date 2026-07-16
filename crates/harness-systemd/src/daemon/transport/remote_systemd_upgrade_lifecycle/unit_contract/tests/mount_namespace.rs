use std::cell::RefCell;

use super::super::mount_namespace::ALTERNATE_MOUNT_PROPERTIES;
use super::*;

#[test]
fn source_mount_namespace_remaps_are_rejected_before_systemctl() {
    for property in ALTERNATE_MOUNT_PROPERTIES {
        let fixture = ContractFixture::new();
        fixture.rewrite_unit(|contents| {
            contents.replace(
                "KillMode=control-group\n",
                &format!("KillMode=control-group\n{property}=/tmp/remap\n"),
            )
        });

        let error = validate_managed_unit_contract(&fixture.plan, &|_| {
            panic!("source remap rejection must happen before systemctl")
        })
        .expect_err("source mount remap must fail closed");

        assert!(error.to_string().contains(property), "{error}");
    }

    let empty_reset = ContractFixture::new();
    empty_reset.rewrite_unit(|contents| {
        contents.replace(
            "KillMode=control-group\n",
            "KillMode=control-group\nBindPaths=\n",
        )
    });
    validate_managed_unit_contract(&empty_reset.plan, &|_| {
        panic!("empty source remap rejection must happen before systemctl")
    })
    .expect_err("empty source remap reset must fail closed");
}

#[test]
fn effective_mount_namespace_remaps_are_queried_and_rejected() {
    let query_fixture = ContractFixture::new();
    let calls = RefCell::new(Vec::<Vec<String>>::new());
    validate_managed_unit_contract(&query_fixture.plan, &|args| {
        calls.borrow_mut().push(args.to_vec());
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: query_fixture.effective_output(),
            stderr: String::new(),
        })
    })
    .expect("omitted optional remap properties remain compatible");
    let calls = calls.into_inner();
    let [show] = calls.as_slice() else {
        panic!("expected one effective systemd query, found {calls:?}");
    };
    for property in ALTERNATE_MOUNT_PROPERTIES {
        assert!(show.contains(&format!("--property={property}")));
    }

    for property in ALTERNATE_MOUNT_PROPERTIES {
        let fixture = ContractFixture::new();
        let output = format!("{}{property}=/tmp/remap\n", fixture.effective_output());
        let error = fixture
            .validate_with(&output)
            .expect_err("effective mount remap must fail closed");
        assert!(error.to_string().contains(property), "{error}");
    }
}

#[test]
fn effective_mount_namespace_empty_values_are_strictly_parsed() {
    let empty = ContractFixture::new();
    let properties = ALTERNATE_MOUNT_PROPERTIES
        .map(|property| format!("{property}=\n"))
        .concat();
    empty
        .validate_with(&format!("{}{properties}", empty.effective_output()))
        .expect("one empty value per remap property");

    for suffix in [
        "BindPaths=\nBindPaths=\n",
        "BindPaths=\nBindPaths=/tmp/remap\n",
    ] {
        let duplicate = ContractFixture::new();
        duplicate
            .validate_with(&format!("{}{suffix}", duplicate.effective_output()))
            .expect_err("duplicate effective remap property must fail closed");
    }
}

use super::*;

#[test]
fn validate_universal_manifest_valid() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("mesh-timeout.yaml");
    fs::write(
        &manifest_path,
        "type: MeshTimeout\nname: timeout-policy\nmesh: default\nspec:\n  targetRef:\n    kind: Mesh\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate universal manifest should succeed: {result:?}"
    );
    assert_eq!(result.unwrap(), 0);

    let output_path = manifest_path.with_extension("validation.json");
    assert!(
        output_path.exists(),
        "validation output should exist at {output_path:?}"
    );
}

#[test]
fn validate_universal_manifest_missing_required_fields() {
    let cases: &[(&str, &str)] = &[
        (
            "name: something\nmesh: default\nspec:\n  key: value\n",
            "missing type",
        ),
        (
            "type: MeshTimeout\nmesh: default\nspec:\n  key: value\n",
            "missing name",
        ),
        (
            "type: MeshTimeout\nname: timeout\nspec:\n  key: value\n",
            "missing mesh",
        ),
    ];
    for (yaml, description) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let manifest_path = tmp.path().join("bad-manifest.yaml");
        fs::write(&manifest_path, yaml).unwrap();
        let result = validate_cmd(ValidateArgs {
            kubeconfig: None,
            manifest: manifest_path.to_string_lossy().to_string(),
            output: None,
        })
        .execute();
        assert!(result.is_err(), "validate should fail for {description}");
    }
}

#[test]
fn validate_universal_manifest_zone_ingress_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone-ingress.yaml");
    fs::write(
        &manifest_path,
        "type: ZoneIngress\nname: ingress-1\nspec:\n  networking:\n    port: 10001\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate ZoneIngress without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_zone_egress_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone-egress.yaml");
    fs::write(
        &manifest_path,
        "type: ZoneEgress\nname: egress-1\nspec:\n  networking:\n    port: 10002\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate ZoneEgress without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_zone_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone.yaml");
    fs::write(
        &manifest_path,
        "type: Zone\nname: zone-east\nspec:\n  address: grpcs://zone-east:5685\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate Zone without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_custom_output_path() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("policy.yaml");
    let output_path = tmp.path().join("custom-output.json");
    fs::write(
        &manifest_path,
        "type: MeshRetry\nname: retry-policy\nmesh: default\nspec:\n  targetRef:\n    kind: Mesh\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: Some(output_path.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "validate with custom output: {result:?}");
    assert!(output_path.exists(), "custom output path should exist");
}

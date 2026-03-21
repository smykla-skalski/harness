use super::*;

#[test]
fn parse_json_body_valid() {
    let value = parse_json_body(r#"{"name":"test","mesh":"default"}"#).unwrap();
    assert_eq!(value["name"], "test");
    assert_eq!(value["mesh"], "default");
}

#[test]
fn parse_json_body_invalid() {
    let result = parse_json_body("not json");
    assert!(result.is_err());
    let error = result.unwrap_err();
    assert!(error.message().contains("invalid JSON in --body"));
}

#[test]
fn method_run_dir_and_path_get() {
    let run_dir = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };
    let method = ApiMethod::Get {
        path: "/zones".to_string(),
        run_dir,
    };
    let (_, path) = method_run_dir_and_path(&method);
    assert_eq!(path, "/zones");
}

#[test]
fn method_run_dir_and_path_post() {
    let run_dir = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };
    let method = ApiMethod::Post {
        path: "/tokens/dataplane".to_string(),
        body: "{}".to_string(),
        run_dir,
    };
    let (_, path) = method_run_dir_and_path(&method);
    assert_eq!(path, "/tokens/dataplane");
}

#[test]
fn method_run_dir_and_path_put() {
    let run_dir = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };
    let method = ApiMethod::Put {
        path: "/meshes/default".to_string(),
        body: "{}".to_string(),
        run_dir,
    };
    let (_, path) = method_run_dir_and_path(&method);
    assert_eq!(path, "/meshes/default");
}

#[test]
fn method_run_dir_and_path_delete() {
    let run_dir = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };
    let method = ApiMethod::Delete {
        path: "/meshes/default/meshtrafficpermissions/allow-all".to_string(),
        run_dir,
    };
    let (_, path) = method_run_dir_and_path(&method);
    assert_eq!(path, "/meshes/default/meshtrafficpermissions/allow-all");
}

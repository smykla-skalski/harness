use super::*;

#[tokio::test]
async fn list_windows_tool_returns_json_text_result() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = json!({
        "id": 1,
        "ok": true,
        "result": {"windows": [{
            "id": 1234,
            "title": "Harness Monitor",
            "role": "AXWindow",
            "frame": {"x": 0.0, "y": 0.0, "width": 800.0, "height": 600.0},
            "isKey": true,
            "isMain": true,
        }]},
    })
    .to_string();
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ListWindowsTool::new(client);
    let result = tool.call(json!({})).await.expect("ok");
    let request_line = server.await.unwrap();
    assert!(!result.is_error);
    assert_eq!(result.content.len(), 1);
    assert!(request_line.contains("\"op\":\"listWindows\""));
}

#[tokio::test]
async fn list_elements_tool_forwards_filters_to_registry() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = json!({
        "id": 1,
        "ok": true,
        "result": {"elements": [{
            "identifier": "button.send",
            "label": "Send",
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 100.0, "y": 200.0, "width": 60.0, "height": 40.0},
            "windowID": 42,
            "enabled": true,
            "selected": false,
            "focused": false,
        }]},
    })
    .to_string();
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ListElementsTool::new(client);
    tool.call(json!({"windowID": 42, "kind": "button"}))
        .await
        .expect("ok");
    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"windowID\":42"));
    assert!(
        request_line.contains("\"kind\":\"button\""),
        "missing kind, got {request_line}",
    );
}

#[tokio::test]
async fn resolve_list_elements_uses_helper_when_registry_is_empty() {
    async fn helper(
        window_id: Option<i64>,
        kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        assert_eq!(window_id, Some(42));
        assert_eq!(kind, Some(ElementKind::Button));
        Ok(ListElementsResult {
            elements: vec![fallback_element("button.fallback", 42, ElementKind::Button)],
        })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("fallback succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.fallback");
    assert_eq!(result.elements[0].window_id, Some(42));
}

#[tokio::test]
async fn resolve_list_elements_preserves_empty_success_when_helper_fails() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Err(AccessibilityQueryError::AccessibilityDenied)
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("empty success is preserved");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_retries_window_scoped_empty_results_until_registry_populates() {
    let helper_calls = AtomicUsize::new(0);

    async fn helper(
        helper_calls: &AtomicUsize,
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        helper_calls.fetch_add(1, Ordering::Relaxed);
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            empty_elements_response(1),
            empty_elements_response(2),
            elements_response(3, "button.ready", 42),
        ],
    );
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), None, |window_id, kind| {
        helper(&helper_calls, window_id, kind)
    })
    .await
    .expect("registry eventually populates");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 3);
    assert_eq!(helper_calls.load(Ordering::Relaxed), 1);
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.ready");
    assert_eq!(result.elements[0].window_id, Some(42));
}

#[tokio::test]
async fn resolve_list_elements_does_not_retry_unscoped_empty_results() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, None, None, helper)
        .await
        .expect("empty unscoped result succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_does_not_retry_kind_filtered_empty_results() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("empty kind-filtered result succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(request_line.contains("\"kind\":\"button\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn get_element_rejects_empty_identifier() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = GetElementTool::new(client);
    let err = tool
        .call(json!({"identifier": ""}))
        .await
        .expect_err("empty identifier rejected");
    assert!(err.message().contains("identifier cannot be empty"));
}

#[tokio::test]
async fn resolve_get_element_uses_helper_when_registry_reports_not_found() {
    async fn helper(identifier: String) -> Result<GetElementResult, AccessibilityQueryError> {
        assert_eq!(identifier, "button.fallback");
        Ok(GetElementResult {
            element: fallback_element("button.fallback", 7, ElementKind::Button),
        })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, not_found_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_get_element_with(&client, "button.fallback", helper)
        .await
        .expect("helper recovers not-found");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"getElement\""));
    assert_eq!(result.element.identifier, "button.fallback");
    assert_eq!(result.element.window_id, Some(7));
}

#[tokio::test]
async fn click_element_targets_frame_center() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response(1);
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ClickElementTool::new(client);
    let _ = tool.call(json!({"identifier": "button.send"})).await;
    let request_line = server.await.unwrap();
    assert!(
        request_line.contains("\"op\":\"getElement\""),
        "missing op, got {request_line}",
    );
    assert!(request_line.contains("\"identifier\":\"button.send\""));
}

#[tokio::test]
async fn press_element_invokes_helper_semantic_action() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response(1);
    let server = spawn_single_response(&path, response);
    let helper = dir.path().join("harness-monitor-input");
    let log_path = dir.path().join("press-action.log");
    write_press_action_helper(&helper, &log_path);
    let helper_path = helper.to_string_lossy().into_owned();
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = PressElementTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))],
        async move { tool.call(json!({"identifier": "button.send"})).await },
    )
    .await
    .expect("semantic action succeeds");
    let request_line = server.await.unwrap();

    assert!(!result.is_error);
    assert!(request_line.contains("\"op\":\"getElement\""));
    assert!(request_line.contains("\"identifier\":\"button.send\""));
    assert_eq!(
        fs::read_to_string(log_path).unwrap(),
        "perform-action --window-id 7 --action press button.send\n"
    );
}

#[tokio::test]
async fn press_element_surfaces_missing_semantic_action_as_tool_error_result() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response(1);
    let server = spawn_single_response(&path, response);
    let helper = dir.path().join("harness-monitor-input");
    write_press_action_failure_helper(
        &helper,
        4,
        "error: no supported accessibility action for identifier: button.send",
    );
    let helper_path = helper.to_string_lossy().into_owned();
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = PressElementTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))],
        async move { tool.call(json!({"identifier": "button.send"})).await },
    )
    .await
    .expect("tool-level error result");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"getElement\""));
    assert!(result.is_error);
    assert_eq!(
        result.content,
        vec![ContentBlock::text(
            "identifier 'button.send' resolves to a live element without a supported semantic press action"
        )]
    );
}

#[tokio::test]
async fn press_element_uses_registry_semantic_action_when_advertised() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            actionable_element_response(1, "button.send"),
            json!({
                "id": 2,
                "ok": true,
                "result": {"applied": true},
            })
            .to_string(),
        ],
    );
    let helper = dir.path().join("harness-monitor-input");
    let helper_log = dir.path().join("helper.log");
    write_helper_script(
        &helper,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\nexit 0\n",
            helper_log.to_string_lossy()
        ),
    );
    let helper_path = helper.to_string_lossy().into_owned();
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = PressElementTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))],
        async move { tool.call(json!({"identifier": "button.send"})).await },
    )
    .await
    .expect("registry semantic action succeeds");
    let request_lines = server.await.unwrap();

    assert!(!result.is_error);
    assert_eq!(request_lines.len(), 2);
    assert!(request_lines[0].contains("\"op\":\"getElement\""));
    assert!(request_lines[1].contains("\"op\":\"performAction\""));
    assert!(request_lines[1].contains("\"action\":\"press\""));
    assert!(
        !helper_log.exists(),
        "registry-first path should not consult helper: {}",
        fs::read_to_string(&helper_log).unwrap_or_default()
    );
}

#[tokio::test]
async fn press_element_falls_back_to_helper_when_registry_press_transport_is_unsupported() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            actionable_element_response(1, "button.send"),
            json!({
                "id": -1,
                "ok": false,
                "error": {
                    "code": "invalid-json",
                    "message": "unknown request op"
                },
            })
            .to_string(),
        ],
    );
    let helper = dir.path().join("harness-monitor-input");
    let log_path = dir.path().join("press-action.log");
    write_press_action_helper(&helper, &log_path);
    let helper_path = helper.to_string_lossy().into_owned();
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = PressElementTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))],
        async move { tool.call(json!({"identifier": "button.send"})).await },
    )
    .await
    .expect("helper fallback succeeds");
    let request_lines = server.await.unwrap();

    assert!(!result.is_error);
    assert_eq!(request_lines.len(), 2);
    assert!(request_lines[0].contains("\"op\":\"getElement\""));
    assert!(request_lines[1].contains("\"op\":\"performAction\""));
    assert_eq!(
        fs::read_to_string(log_path).unwrap(),
        "perform-action --window-id 7 --action press button.send\n"
    );
}

#[tokio::test]
async fn press_element_surfaces_registry_action_unavailable_without_helper_fallback() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            actionable_element_response(1, "button.send"),
            json!({
                "id": 2,
                "ok": false,
                "error": {
                    "code": "action-unavailable",
                    "message": "no semantic action handler"
                },
            })
            .to_string(),
        ],
    );
    let helper = dir.path().join("harness-monitor-input");
    let helper_log = dir.path().join("helper.log");
    write_helper_script(
        &helper,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\nexit 0\n",
            helper_log.to_string_lossy()
        ),
    );
    let helper_path = helper.to_string_lossy().into_owned();
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = PressElementTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))],
        async move { tool.call(json!({"identifier": "button.send"})).await },
    )
    .await
    .expect("tool-level error result");
    let request_lines = server.await.unwrap();

    assert!(result.is_error);
    assert_eq!(request_lines.len(), 2);
    assert!(request_lines[1].contains("\"op\":\"performAction\""));
    assert_eq!(
        result.content,
        vec![ContentBlock::text(
            "identifier 'button.send' resolves to a live element without a supported semantic press action"
        )]
    );
    assert!(
        !helper_log.exists(),
        "action-unavailable should not drop to helper: {}",
        fs::read_to_string(&helper_log).unwrap_or_default()
    );
}

#[tokio::test]
async fn scroll_tool_queries_registry_for_identifier() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response_with(
        1,
        "harness.session.cockpit.scroll",
        10.0,
        20.0,
        200.0,
        120.0,
    );
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ScrollTool::new(client);
    let _ = tool
        .call(json!({"identifier": "harness.session.cockpit.scroll", "deltaY": 180}))
        .await;
    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"op\":\"getElement\""));
    assert!(request_line.contains("\"identifier\":\"harness.session.cockpit.scroll\""));
}

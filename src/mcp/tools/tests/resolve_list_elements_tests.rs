use super::*;

fn counted_empty_helper(
    helper_calls: &AtomicUsize,
    _window_id: Option<i64>,
    _kind: Option<ElementKind>,
) -> std::future::Ready<Result<ListElementsResult, AccessibilityQueryError>> {
    helper_calls.fetch_add(1, Ordering::Relaxed);
    std::future::ready(Ok(ListElementsResult { elements: vec![] }))
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
    let server = spawn_response_sequence(
        &path,
        vec![
            empty_elements_response(1),
            empty_elements_response(2),
            empty_elements_response(3),
            empty_elements_response(4),
            empty_elements_response(5),
        ],
    );
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("empty success is preserved");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 5);
    assert!(
        request_lines
            .iter()
            .all(|line| line.contains("\"op\":\"listElements\"")),
    );
    assert!(request_lines[0].contains("\"kind\":\"button\""));
    assert!(!request_lines[1].contains("\"kind\""));
    assert!(request_lines[2].contains("\"kind\":\"button\""));
    assert!(request_lines[3].contains("\"kind\":\"button\""));
    assert!(request_lines[4].contains("\"kind\":\"button\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_retries_window_scoped_empty_results_until_registry_populates() {
    let helper_calls = AtomicUsize::new(0);

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
        counted_empty_helper(&helper_calls, window_id, kind)
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
async fn resolve_list_elements_retries_unscoped_empty_results_until_registry_populates() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
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
    let result = resolve_list_elements_with(&client, None, None, helper)
        .await
        .expect("registry eventually populates");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 3);
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.ready");
}

#[tokio::test]
async fn resolve_list_elements_retries_kind_filtered_empty_results_until_registry_populates() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
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
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("registry eventually populates");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 3);
    assert!(request_lines[0].contains("\"windowID\":42"));
    assert!(request_lines[0].contains("\"kind\":\"button\""));
    assert!(request_lines[1].contains("\"windowID\":42"));
    assert!(!request_lines[1].contains("\"kind\""));
    assert!(request_lines[2].contains("\"windowID\":42"));
    assert!(request_lines[2].contains("\"kind\":\"button\""));
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.ready");
}

#[tokio::test]
async fn resolve_list_elements_does_not_retry_kind_filtered_miss_when_scope_has_elements() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            empty_elements_response(1),
            elements_response(2, "button.other", 42),
        ],
    );
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Text), helper)
        .await
        .expect("filtered miss succeeds");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 2);
    assert!(request_lines[0].contains("\"windowID\":42"));
    assert!(request_lines[0].contains("\"kind\":\"text\""));
    assert!(request_lines[1].contains("\"windowID\":42"));
    assert!(!request_lines[1].contains("\"kind\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_preserves_empty_success_when_registry_stays_empty() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            empty_elements_response(1),
            empty_elements_response(2),
            empty_elements_response(3),
            empty_elements_response(4),
        ],
    );
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), None, helper)
        .await
        .expect("stable empty result succeeds");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 4);
    assert!(
        request_lines
            .iter()
            .all(|line| line.contains("\"windowID\":42")),
    );
    assert!(request_lines.iter().all(|line| !line.contains("\"kind\"")),);
    assert!(result.elements.is_empty());
}

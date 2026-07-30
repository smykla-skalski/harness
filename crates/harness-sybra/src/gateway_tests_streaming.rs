use super::*;

#[tokio::test]
async fn event_tokens_are_consumed_and_streams_have_dedicated_capacity() {
    let edge = TestEdge::new(SybraOwnershipRegistry::default_upstream(), 1, 1).await;
    assert_malformed_and_denied_event_requests(&edge).await;
    assert_named_event_then_capacity_then_release(&edge).await;
}

async fn assert_malformed_and_denied_event_requests(edge: &TestEdge) {
    let malformed = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            "/events?token=%zz",
            true,
            Body::empty(),
        ))
        .await
        .expect("malformed query");
    assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
    assert_eq!(edge.count(), 0);

    let malformed_rpc = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            "/api/A/B?trace=%zz",
            true,
            Body::empty(),
        ))
        .await
        .expect("malformed RPC query");
    assert_eq!(malformed_rpc.status(), StatusCode::BAD_REQUEST);
    assert!(
        body_text(malformed_rpc)
            .await
            .contains("Sybra query is malformed")
    );
    assert_eq!(edge.count(), 0);

    for uri in ["/events", "/events?token=wrong-browser-token-000000000"] {
        let denied = edge
            .router
            .clone()
            .oneshot(request(Method::GET, uri, false, Body::empty()))
            .await
            .expect("denied event source");
        assert_eq!(denied.status(), StatusCode::UNAUTHORIZED, "{uri}");
        assert_eq!(edge.count(), 0);
    }
}

async fn assert_named_event_then_capacity_then_release(edge: &TestEdge) {
    let named = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            &format!("/api/events/task.created?token={BROWSER_TOKEN}"),
            false,
            Body::empty(),
        ))
        .await
        .expect("named event");
    assert_eq!(named.status(), StatusCode::OK);
    assert_eq!(body_text(named).await, "data: delayed\n\n");
    assert_eq!(edge.last().path_and_query, "/api/events/task.created");
    assert_eq!(
        edge.last().authorization,
        Some(format!("Bearer {PRIVATE_TOKEN}"))
    );

    let held = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            &format!("/events?hold=1&token={BROWSER_TOKEN}"),
            false,
            Body::empty(),
        ))
        .await
        .expect("held stream");
    assert_eq!(held.status(), StatusCode::OK);
    let captured = edge.last();
    assert_eq!(captured.path_and_query, "/events?hold=1");
    assert!(!captured.path_and_query.contains(BROWSER_TOKEN));
    assert!(!captured.path_and_query.contains(PRIVATE_TOKEN));
    assert_eq!(
        captured.authorization,
        Some(format!("Bearer {PRIVATE_TOKEN}"))
    );

    let capacity = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/events", true, Body::empty()))
        .await
        .expect("capacity");
    assert_eq!(capacity.status(), StatusCode::TOO_MANY_REQUESTS);
    let ordinary = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/asset", false, Body::empty()))
        .await
        .expect("ordinary");
    assert_eq!(ordinary.status(), StatusCode::OK);

    drop(held);
    for _ in 0..20 {
        let response = edge
            .router
            .clone()
            .oneshot(request(Method::GET, "/events", true, Body::empty()))
            .await
            .expect("released stream");
        if response.status() == StatusCode::OK {
            assert_eq!(body_text(response).await, "data: delayed\n\n");
            return;
        }
        sleep(Duration::from_millis(5)).await;
    }
    panic!("stream permit was not released");
}

#[tokio::test]
async fn default_stream_capacity_accepts_five_long_lived_tabs() {
    let edge = TestEdge::new_default().await;
    let mut streams = Vec::new();
    for index in 0..5 {
        let response = edge
            .router
            .clone()
            .oneshot(request(
                Method::GET,
                &format!("/events?hold=1&tab={index}&token={BROWSER_TOKEN}"),
                false,
                Body::empty(),
            ))
            .await
            .expect("long-lived stream");
        assert_eq!(response.status(), StatusCode::OK);
        streams.push(response);
    }
    assert_eq!(streams.len(), 5);
    assert_eq!(edge.count(), 5);
}

#[tokio::test]
async fn ordinary_deadlines_and_body_bounds_do_not_apply_to_sse_bodies() {
    let edge = TestEdge::new(SybraOwnershipRegistry::default_upstream(), 1, 1).await;
    let timed_out = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/slow", false, Body::empty()))
        .await
        .expect("timeout response");
    assert_eq!(timed_out.status(), StatusCode::GATEWAY_TIMEOUT);

    let oversized = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            "/api/A/B",
            true,
            Body::from(vec![b'x'; 4 * 1024 * 1024 + 1]),
        ))
        .await
        .expect("oversized response");
    assert_eq!(oversized.status(), StatusCode::PAYLOAD_TOO_LARGE);

    let large_body = vec![b'1'; 4 * 1024 * 1024 + 1];
    let upload = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            "/api/TaskService/UploadAttachment",
            true,
            Body::from(large_body.clone()),
        ))
        .await
        .expect("large upload");
    assert_eq!(upload.status(), StatusCode::OK);
    assert_eq!(body_text(upload).await, "upstream");
    assert_eq!(edge.last().body.len(), large_body.len());

    let mut beyond_limit = request(
        Method::POST,
        "/api/TaskService/UploadAttachment",
        true,
        Body::empty(),
    );
    beyond_limit.headers_mut().insert(
        CONTENT_LENGTH,
        (UPLOAD_ATTACHMENT_BODY_BYTES + 1)
            .to_string()
            .parse()
            .expect("content length"),
    );
    let requests_before = edge.count();
    let rejected_upload = edge
        .router
        .clone()
        .oneshot(beyond_limit)
        .await
        .expect("rejected upload");
    assert_eq!(rejected_upload.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(edge.count(), requests_before);

    let slow_body = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/slow-body", false, Body::empty()))
        .await
        .expect("slow body response");
    assert_eq!(slow_body.status(), StatusCode::OK);
    assert!(slow_body.into_body().collect().await.is_err());

    let stream = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/events", true, Body::empty()))
        .await
        .expect("stream");
    assert_eq!(stream.status(), StatusCode::OK);
    assert_eq!(body_text(stream).await, "data: delayed\n\n");
}

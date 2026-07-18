use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use super::*;
use crate::task_board::external::TodoistSyncClient;

#[derive(Debug, Default)]
struct CapturedRequest {
    method: String,
    path: String,
}

#[tokio::test]
async fn close_clears_revision_before_reopen_skips_closed_task_preflight() {
    let (endpoint, captured, handle) = spawn_close_reopen_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut closing = linked_item();
    closing.title = "Base title".into();
    closing.status = TaskBoardStatus::Done;
    let close_store = failing_store(&closing, true, None);
    let mut operations = Vec::new();

    let close_result = update_linked_remote(
        &close_store,
        applied_options(),
        &client,
        None,
        &closing,
        reference.clone(),
        &mut operations,
    )
    .await;
    assert!(close_result.is_ok(), "close task");
    let mut reopening = close_store
        .updated_items
        .lock()
        .expect("updated items")
        .first()
        .expect("closed item")
        .clone();
    reopening.status = TaskBoardStatus::Todo;
    let reopen_store = failing_store(&reopening, true, None);
    let reopen_result = update_linked_remote(
        &reopen_store,
        applied_options(),
        &client,
        None,
        &reopening,
        reference,
        &mut operations,
    )
    .await;

    handle.join().expect("mock server");
    let revision = reopening.external_refs[0]
        .sync_state
        .as_ref()
        .and_then(|state| state.updated_at.as_deref());
    assert_eq!(revision, None, "close must clear stale provider revision");
    assert!(
        reopen_result.is_ok(),
        "reopen without unavailable closed-task preflight"
    );
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 3);
    assert_eq!(
        (captured[0].method.as_str(), captured[0].path.as_str()),
        ("GET", "/tasks/remote-1")
    );
    assert_eq!(
        (captured[1].method.as_str(), captured[1].path.as_str()),
        ("POST", "/tasks/remote-1/close")
    );
    assert_eq!(
        (captured[2].method.as_str(), captured[2].path.as_str()),
        ("POST", "/tasks/remote-1/reopen")
    );
}

fn applied_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        dry_run: false,
        ..ExternalSyncOptions::default()
    }
}

fn spawn_close_reopen_mock() -> (
    String,
    Arc<Mutex<Vec<CapturedRequest>>>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Vec::new()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        for index in 0..3 {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = capture_request(&read_http_request(&mut stream));
            let is_reopen = request.path.ends_with("/reopen");
            captured_clone
                .lock()
                .expect("captured requests")
                .push(request);
            match index {
                0 => write_http_response(
                    &mut stream,
                    "200 OK",
                    r#"{"id":"remote-1","content":"Base title","description":"Body","updated_at":"provider-revision-1"}"#,
                ),
                1 => write_http_response(&mut stream, "204 No Content", ""),
                _ if is_reopen => write_http_response(&mut stream, "204 No Content", ""),
                _ => write_http_response(&mut stream, "404 Not Found", ""),
            }
        }
    });
    (endpoint, captured, handle)
}

fn capture_request(request: &str) -> CapturedRequest {
    let mut request_line = request
        .lines()
        .next()
        .unwrap_or_default()
        .split_whitespace();
    CapturedRequest {
        method: request_line.next().unwrap_or_default().into(),
        path: request_line.next().unwrap_or_default().into(),
    }
}

fn read_http_request(stream: &mut TcpStream) -> String {
    stream.set_nonblocking(false).expect("blocking stream");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(1)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8(buffer).expect("utf8 request")
}

fn write_http_response(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

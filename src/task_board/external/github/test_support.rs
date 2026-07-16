use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Default)]
pub(super) struct CapturedRequest {
    pub(super) method: String,
    pub(super) path: String,
    pub(super) body: String,
}

pub(super) struct MockResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl MockResponse {
    pub(super) fn json(body: impl Into<String>) -> Self {
        Self {
            status: 200,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    pub(super) fn status(status: u16, body: impl Into<String>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    #[must_use]
    pub(super) fn with_header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_owned(), value.into()));
        self
    }
}

pub(super) fn spawn_sequence_mock(
    responses: Vec<MockResponse>,
) -> (
    String,
    Arc<Mutex<Vec<CapturedRequest>>>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    listener.set_nonblocking(true).expect("nonblocking");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Vec::new()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        for response in responses {
            let mut stream = accept_before_deadline(&listener);
            let request = read_http_request(&mut stream);
            captured_clone
                .lock()
                .expect("captured requests")
                .push(capture_request(&request));
            write_response(&mut stream, response);
        }
    });
    (endpoint, captured, handle)
}

fn accept_before_deadline(listener: &TcpListener) -> TcpStream {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match listener.accept() {
            Ok((stream, _)) => return stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "timed out waiting for request");
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("accept request: {error}"),
        }
    }
}

fn read_http_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
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
    read_http_request_body(stream, &mut buffer);
    String::from_utf8(buffer).expect("utf8 request")
}

fn read_http_request_body(stream: &mut TcpStream, buffer: &mut Vec<u8>) {
    let header_end = buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map_or(buffer.len(), |position| position + 4);
    let headers = String::from_utf8(buffer[..header_end].to_vec()).expect("utf8 headers");
    let content_length = headers
        .lines()
        .find_map(|line| {
            line.split_once(':').and_then(|(name, value)| {
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
        })
        .unwrap_or_default();
    while buffer.len().saturating_sub(header_end) < content_length {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request body");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
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
        body: request.split("\r\n\r\n").nth(1).unwrap_or_default().into(),
    }
}

fn write_response(stream: &mut TcpStream, response: MockResponse) {
    let reason = if response.status == 200 {
        "OK"
    } else {
        "Server Error"
    };
    let extra_headers = response
        .headers
        .into_iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();
    let raw = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: application/json\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
        response.status,
        response.body.len(),
        response.body
    );
    stream.write_all(raw.as_bytes()).expect("write response");
    stream.flush().expect("flush response");
}

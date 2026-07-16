use std::io::Cursor;
use std::path::Path;
use std::time::{Duration, Instant};

use super::sha256_reader_until;

#[test]
fn bounded_digest_stops_at_deadline_and_completes_with_time_remaining() {
    let path = Path::new("memory");
    let expired_deadline = Some(Instant::now());
    let expired_result = sha256_reader_until(Cursor::new(b"digest input"), path, expired_deadline);
    let expired = expired_result.expect("expired digest check");
    assert_eq!(expired, None);

    let deadline = Instant::now().checked_add(Duration::from_secs(1));
    let completed_result = sha256_reader_until(Cursor::new(b"digest input"), path, deadline);
    let completed = completed_result.expect("bounded digest");
    assert_eq!(
        completed.as_deref(),
        Some("64be17c8f76af27b57c2f7bd413bcff919c394744d689054fec013a40f9be9e5")
    );
}

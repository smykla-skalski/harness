use super::*;

#[test]
fn system_clock_produces_valid_iso8601() {
    let clock = SystemClock;
    let now = clock.now_iso8601();
    assert!(
        now.contains('T'),
        "expected ISO 8601 with T separator: {now}"
    );
    assert!(now.ends_with('Z'), "expected UTC suffix Z: {now}");
}

#[test]
fn system_clock_rfc3339_matches_iso8601() {
    let clock = SystemClock;
    assert_eq!(clock.now_iso8601(), clock.now_rfc3339());
}

#[test]
fn fake_clock_returns_fixed_value() {
    let clock = FakeClock("2026-01-01T00:00:00Z".to_string());
    assert_eq!(clock.now_iso8601(), "2026-01-01T00:00:00Z");
    assert_eq!(clock.now_rfc3339(), "2026-01-01T00:00:00Z");
}

#[test]
fn clock_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<SystemClock>();
    assert_send_sync::<FakeClock>();
}

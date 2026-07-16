/// Return current UTC time as ISO 8601 with a `Z` suffix.
#[must_use]
pub fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

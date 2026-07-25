use super::{normalize_optional_value, normalize_repository_slug};

#[test]
fn normalize_repository_slug_rejects_invalid_values() {
    assert_eq!(
        normalize_repository_slug(Some(" owner/repo ")),
        Some("owner/repo".into())
    );
    assert_eq!(normalize_repository_slug(Some("owner/repo/extra")), None);
    assert_eq!(normalize_repository_slug(Some("owner")), None);
    assert_eq!(normalize_repository_slug(Some(" ")), None);
}

#[test]
fn normalize_optional_value_treats_blank_as_absent() {
    assert_eq!(
        normalize_optional_value(Some("  value  ")),
        Some("value".into())
    );
    assert_eq!(normalize_optional_value(Some("   ")), None);
    assert_eq!(normalize_optional_value(None), None);
}

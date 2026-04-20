use super::*;

#[test]
fn generates_8_lowercase_alphanumeric_chars() {
    for _ in 0..200 {
        let id = new_session_id();
        assert_eq!(id.len(), 8, "id: {id}");
        assert!(
            id.chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()),
            "id: {id}",
        );
    }
}

#[test]
fn validate_rejects_invalid() {
    assert!(validate("abc12345").is_ok());
    assert!(validate("ABCDEFGH").is_err());
    assert!(validate("abc-1234").is_err());
    assert!(validate("abc1234").is_err());
    assert!(validate("abc123456").is_err());
    assert!(validate("").is_err());
}

#[test]
fn generated_ids_pass_validation() {
    for _ in 0..50 {
        validate(&new_session_id()).expect("generated id must validate");
    }
}

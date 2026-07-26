use super::*;

#[test]
fn generates_lowercase_uuid_v4() {
    for _ in 0..200 {
        let id = new_session_id();
        assert_eq!(id.len(), SESSION_ID_LEN, "id: {id}");
        let parsed = uuid::Uuid::parse_str(&id).expect("generated id parses as UUID");
        assert_eq!(id, parsed.to_string(), "id must be canonical lowercase");
    }
}

#[test]
fn validate_rejects_invalid() {
    assert!(validate("550e8400-e29b-41d4-a716-446655440000").is_ok());
    assert!(validate("550E8400-E29B-41D4-A716-446655440000").is_err());
    assert!(validate("72026b9c9f8f5a76a6cfa05cbb5741ed").is_err());
    assert!(validate("00b4a39f-719e-5418-abe8-eb3ab6ea614d0260506193040829413000").is_err());
    assert!(validate("").is_err());
}

#[test]
fn generated_ids_pass_validation() {
    for _ in 0..50 {
        validate(&new_session_id()).expect("generated id must validate");
    }
}

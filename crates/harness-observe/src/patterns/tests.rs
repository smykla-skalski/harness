use super::KSA_CODES;

#[test]
fn ksa_codes_count() {
    assert_eq!(KSA_CODES.len(), 19);
}

#[test]
fn ksa_codes_sequential() {
    for (index, code) in KSA_CODES.iter().enumerate() {
        let expected = format!("ksa{:03}", index + 1);
        assert_eq!(*code, expected);
    }
}

use crate::task_board::{ExternalProvider, ExternalRefProvider};

#[test]
fn github_providers_use_canonical_wire_name_and_accept_legacy_values() {
    assert_eq!(
        serde_json::to_string(&ExternalProvider::GitHub).expect("serialize external provider"),
        r#""github""#
    );
    assert_eq!(
        serde_json::to_string(&ExternalRefProvider::GitHub)
            .expect("serialize external reference provider"),
        r#""github""#
    );
    assert_eq!(
        serde_json::from_str::<ExternalProvider>(r#""git_hub""#)
            .expect("decode legacy external provider"),
        ExternalProvider::GitHub
    );
    assert_eq!(
        serde_json::from_str::<ExternalRefProvider>(r#""git_hub""#)
            .expect("decode legacy external reference provider"),
        ExternalRefProvider::GitHub
    );
}

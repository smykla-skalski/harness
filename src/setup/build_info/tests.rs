use super::BuildInfo;

#[test]
fn build_info_env() {
    let info = BuildInfo {
        version: "1.2.3".into(),
    };
    let env = info.env();
    assert_eq!(env.get("BUILD_INFO_VERSION").unwrap(), "1.2.3");
}

use super::*;

#[test]
fn data_root_prefers_xdg_data_home() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        assert_eq!(data_root(), xdg_data);
    });
}

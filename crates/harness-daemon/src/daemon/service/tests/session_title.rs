use super::*;

#[test]
fn update_session_title_db_direct_updates_sqlite() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);

        let updated = update_session_title_direct(
            &state.session_id,
            &crate::daemon::protocol::SessionTitleRequest {
                title: "renamed from sqlite".into(),
            },
            &db,
        )
        .expect("update title via db");

        assert_eq!(updated.title, "renamed from sqlite");
        let db_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("state present");
        assert_eq!(db_state.title, "renamed from sqlite");
    });
}

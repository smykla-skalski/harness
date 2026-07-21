use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalTask, ExternalTaskRef, TaskBoardStatus,
};

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

#[test]
fn external_task_omits_a_false_tracks_children_from_the_wire() {
    let mut task = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#1"),
        title: "Issue".into(),
        status: TaskBoardStatus::Backlog,
        ..ExternalTask::default()
    };
    let value = serde_json::to_value(&task).expect("serialize external task");
    assert!(value.get("tracks_children").is_none());

    task.tracks_children = true;
    let value = serde_json::to_value(&task).expect("serialize external task");
    assert_eq!(value.get("tracks_children"), Some(&serde_json::json!(true)));
}

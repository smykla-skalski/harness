use super::*;

#[test]
fn github_slug_is_normalized_to_lowercase_owner_and_repository() {
    assert_eq!(
        TaskBoardProjectSource::GitHub.normalize_slug(" Acme/Widgets "),
        Some("acme/widgets".into())
    );
}

#[test]
fn github_slug_requires_exactly_one_separator() {
    assert_eq!(TaskBoardProjectSource::GitHub.normalize_slug("acme"), None);
    assert_eq!(
        TaskBoardProjectSource::GitHub.normalize_slug("acme/widgets/extra"),
        None
    );
    assert_eq!(TaskBoardProjectSource::GitHub.normalize_slug("acme/"), None);
}

#[test]
fn provider_slugs_keep_their_case_because_the_provider_owns_them() {
    assert_eq!(
        TaskBoardProjectSource::Todoist.normalize_slug("  2334Ab  "),
        Some("2334Ab".into())
    );
    assert_eq!(
        TaskBoardProjectSource::Manual.normalize_slug(" Side Quests "),
        Some("Side Quests".into())
    );
    assert_eq!(TaskBoardProjectSource::Manual.normalize_slug("   "), None);
}

/// One spelling reaches the database, the wire, and `parse`. Serde's
/// `snake_case` would spell `GitHub` as `git_hub` and quietly diverge from the
/// column's CHECK constraint.
#[test]
fn a_source_spells_itself_the_same_way_everywhere() {
    for source in [
        TaskBoardProjectSource::GitHub,
        TaskBoardProjectSource::Todoist,
        TaskBoardProjectSource::Manual,
    ] {
        let stored = source.as_str();
        assert_eq!(
            serde_json::to_string(&source).expect("source serializes"),
            format!("\"{stored}\"")
        );
        assert_eq!(TaskBoardProjectSource::parse(stored), Some(source));
    }
}

#[test]
fn generated_identifiers_are_unique_and_recognizable() {
    let first = TaskBoardProject::generate_id();
    let second = TaskBoardProject::generate_id();

    assert_ne!(first, second);
    assert!(is_project_id(&first), "{first} reads as a project id");
    assert!(is_project_id(&second), "{second} reads as a project id");
}

#[test]
fn provider_project_values_are_not_mistaken_for_identifiers() {
    // What `project_id` carries: Todoist project ids and repository slugs.
    // Telling them apart is what keeps a raw value off the card.
    for legacy in ["acme/widgets", "2334Ab", "project-17", "", "project-xyz"] {
        assert!(!is_project_id(legacy), "{legacy} is not a project id");
    }
}

#[test]
fn display_name_wins_over_slug_and_falls_back_to_it() {
    let mut project = project("acme/widgets");
    assert_eq!(project.label(), "acme/widgets");

    project.display_name = Some("Widgets".into());
    assert_eq!(project.label(), "Widgets");
}

#[test]
fn an_assigned_identifier_is_left_alone() {
    let mut item = item();
    item.source_project_id = Some(TaskBoardProject::generate_id());
    item.execution_repository = Some("acme/widgets".into());

    assert_eq!(item_attribution(&item), ItemProjectAttribution::Assigned);
}

#[test]
fn a_github_import_is_attributed_through_its_execution_repository() {
    let mut item = item();
    item.execution_repository = Some("Acme/Widgets".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);

    assert_eq!(
        item_attribution(&item),
        ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, "acme/widgets".into())
    );
}

#[test]
fn a_repository_slug_in_the_provider_column_reads_as_a_github_project() {
    let mut item = item();
    item.project_id = Some("acme/widgets".into());

    assert_eq!(
        item_attribution(&item),
        ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, "acme/widgets".into())
    );
}

#[test]
fn a_provider_project_keeps_its_provider_as_the_source() {
    let mut item = item();
    item.project_id = Some("2334Ab".into());
    item.imported_from_provider = Some(ExternalRefProvider::Todoist);

    assert_eq!(
        item_attribution(&item),
        ItemProjectAttribution::Register(TaskBoardProjectSource::Todoist, "2334Ab".into())
    );
}

#[test]
fn a_hand_made_grouping_is_a_manual_project() {
    let mut item = item();
    item.project_id = Some("Side Quests".into());

    assert_eq!(
        item_attribution(&item),
        ItemProjectAttribution::Register(TaskBoardProjectSource::Manual, "Side Quests".into())
    );
}

#[test]
fn an_explicit_project_wins_over_the_execution_target() {
    // The two can legitimately differ: work owned by one repository can be
    // executed against a checkout of another.
    let mut item = item();
    item.project_id = Some("acme/source".into());
    item.execution_repository = Some("acme/target".into());

    assert_eq!(
        item_attribution(&item),
        ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, "acme/source".into())
    );
}

#[test]
fn an_item_with_no_origin_is_unattributed() {
    assert_eq!(item_attribution(&item()), ItemProjectAttribution::Unattributed);

    let mut blank = item();
    blank.project_id = Some("   ".into());
    assert_eq!(item_attribution(&blank), ItemProjectAttribution::Unattributed);
}

fn item() -> crate::task_board::TaskBoardItem {
    crate::task_board::TaskBoardItem::new(
        "task-1".into(),
        "Task".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    )
}

fn project(slug: &str) -> TaskBoardProject {
    TaskBoardProject {
        project_id: TaskBoardProject::generate_id(),
        source: TaskBoardProjectSource::GitHub,
        slug: slug.into(),
        display_name: None,
        created_at: "2026-07-24T00:00:00Z".into(),
        updated_at: "2026-07-24T00:00:00Z".into(),
    }
}

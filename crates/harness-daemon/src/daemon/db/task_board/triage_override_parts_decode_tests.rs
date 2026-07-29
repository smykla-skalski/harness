use super::override_from_parts;

#[test]
fn all_four_columns_absent_is_no_override() {
    let result = override_from_parts(None, None, None, None).expect("decode");
    assert!(result.is_none());
}

#[test]
fn a_reason_with_no_verdict_is_rejected() {
    override_from_parts(None, None, Some("looks ready".into()), None)
        .expect_err("reason-only tuple must fail closed, not read as no override");
}

#[test]
fn a_verdict_with_no_actor_is_rejected() {
    override_from_parts(
        Some("todo".into()),
        None,
        None,
        Some("2026-07-23T00:00:00Z".into()),
    )
    .expect_err("verdict without actor must fail closed");
}

#[test]
fn a_verdict_with_no_set_at_is_rejected() {
    override_from_parts(Some("todo".into()), Some("operator-1".into()), None, None)
        .expect_err("verdict without set_at must fail closed");
}

#[test]
fn an_actor_and_set_at_with_no_verdict_is_rejected() {
    override_from_parts(
        None,
        Some("operator-1".into()),
        None,
        Some("2026-07-23T00:00:00Z".into()),
    )
    .expect_err("actor/set_at without a verdict must fail closed, not read as no override");
}

#[test]
fn a_fully_populated_tuple_decodes() {
    let result = override_from_parts(
        Some("todo".into()),
        Some("operator-1".into()),
        None,
        Some("2026-07-23T00:00:00Z".into()),
    )
    .expect("decode")
    .expect("override present");
    assert_eq!(result.actor, "operator-1");
}

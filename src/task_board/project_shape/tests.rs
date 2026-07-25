use super::{
    TaskBoardProjectShape, allocate, colors_alone_suffice, organization_of,
};
use crate::task_board::project_color::TaskBoardProjectColor;

#[test]
fn every_shape_round_trips_through_its_wire_name() {
    for shape in TaskBoardProjectShape::SHAPES {
        assert_eq!(TaskBoardProjectShape::parse(shape.as_str()), Some(shape));
    }
}

#[test]
fn shape_names_are_unique() {
    let mut names: Vec<&str> = TaskBoardProjectShape::SHAPES
        .iter()
        .map(|shape| shape.as_str())
        .collect();
    names.sort_unstable();
    let total = names.len();
    names.dedup();
    assert_eq!(names.len(), total);
}

#[test]
fn an_unknown_shape_is_not_guessed_at() {
    assert_eq!(TaskBoardProjectShape::parse("octagon"), None);
    assert_eq!(TaskBoardProjectShape::parse(""), None);
}

#[test]
fn allocation_fills_every_shape_before_repeating_one() {
    let mut taken = Vec::new();
    for _ in 0..TaskBoardProjectShape::SHAPES.len() {
        taken.push(allocate(&taken));
    }
    let mut seen = taken.clone();
    seen.sort_unstable_by_key(|shape| shape.as_str());
    seen.dedup();
    assert_eq!(seen.len(), TaskBoardProjectShape::SHAPES.len());
    assert_eq!(taken[0], TaskBoardProjectShape::DEFAULT);
}

#[test]
fn allocation_past_the_shapes_reuses_the_least_held_one() {
    let mut taken: Vec<_> = TaskBoardProjectShape::SHAPES.into();
    taken.push(TaskBoardProjectShape::SHAPES[0]);
    assert_eq!(allocate(&taken), TaskBoardProjectShape::SHAPES[1]);
}

#[test]
fn the_organization_is_the_owner_half_of_a_slug() {
    assert_eq!(organization_of("smykla-skalski/harness"), "smykla-skalski");
    assert_eq!(organization_of("kumahq/kuma"), "kumahq");
}

#[test]
fn a_slug_without_an_owner_is_its_own_organization() {
    assert_eq!(organization_of("scratch"), "scratch");
    assert_eq!(organization_of(""), "");
}

#[test]
fn shape_stays_out_of_the_way_until_the_colors_run_out() {
    let palette = TaskBoardProjectColor::PALETTE.len();
    assert!(colors_alone_suffice(0));
    assert!(colors_alone_suffice(palette));
    assert!(!colors_alone_suffice(palette + 1));
}

#[test]
fn a_derived_shape_is_stable_for_a_given_organization() {
    let first = TaskBoardProjectShape::derived("acme");
    let second = TaskBoardProjectShape::derived("acme");

    assert_eq!(first, second, "a derived shape that moves is not a fallback");
}

#[test]
fn both_repositories_of_one_owner_derive_the_same_shape() {
    let widgets = TaskBoardProjectShape::derived(organization_of("acme/widgets"));
    let gadgets = TaskBoardProjectShape::derived(organization_of("acme/gadgets"));

    assert_eq!(widgets, gadgets, "the fallback split one organization in two");
}

#[test]
fn derived_shapes_spread_across_the_set() {
    let spread: std::collections::BTreeSet<_> = (0..200)
        .map(|index| TaskBoardProjectShape::derived(&format!("org-{index:04x}")))
        .collect();

    assert_eq!(
        spread.len(),
        TaskBoardProjectShape::SHAPES.len(),
        "derived shapes collapsed onto {} of {} entries",
        spread.len(),
        TaskBoardProjectShape::SHAPES.len()
    );
}

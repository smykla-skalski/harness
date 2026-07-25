use super::{TaskBoardProjectColor, allocate};

#[test]
fn every_palette_entry_round_trips_through_its_wire_name() {
    for color in TaskBoardProjectColor::PALETTE {
        assert_eq!(
            TaskBoardProjectColor::parse(color.as_str()),
            Some(color),
            "{} did not round trip",
            color.as_str()
        );
    }
}

#[test]
fn palette_wire_names_are_distinct() {
    let mut names: Vec<&str> = TaskBoardProjectColor::PALETTE
        .iter()
        .map(|color| color.as_str())
        .collect();
    let total = names.len();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), total, "two palette entries share a wire name");
}

/// The board's whole point is telling projects apart at a glance, so an
/// allocation that hands out a color another project already holds while the
/// palette still has room defeats the feature for both of them.
#[test]
fn allocation_exhausts_the_palette_before_reusing_a_color() {
    let mut taken: Vec<TaskBoardProjectColor> = Vec::new();
    for _ in TaskBoardProjectColor::PALETTE {
        let next = allocate(&taken);
        assert!(
            !taken.contains(&next),
            "{} was handed out twice with the palette not yet exhausted",
            next.as_str()
        );
        taken.push(next);
    }
    assert_eq!(taken.len(), TaskBoardProjectColor::PALETTE.len());
}

/// Past exhaustion the guarantee cannot hold, so the next best thing is
/// spreading the reuse rather than piling every extra project onto one color.
#[test]
fn allocation_past_exhaustion_reuses_the_least_used_color() {
    let mut taken: Vec<TaskBoardProjectColor> = TaskBoardProjectColor::PALETTE.to_vec();
    taken.push(TaskBoardProjectColor::PALETTE[0]);

    assert_eq!(allocate(&taken), TaskBoardProjectColor::PALETTE[1]);
}

#[test]
fn allocation_ignores_a_color_outside_the_palette_count() {
    assert_eq!(allocate(&[]), TaskBoardProjectColor::PALETTE[0]);
}

/// A stored value the palette no longer knows still has to render as some
/// color, and every machine has to pick the same one or the project stops
/// looking the same across them.
#[test]
fn derived_color_is_stable_for_a_given_project() {
    let first = TaskBoardProjectColor::derived("project-0123456789abcdef0123456789abcdef");
    let second = TaskBoardProjectColor::derived("project-0123456789abcdef0123456789abcdef");
    assert_eq!(first, second);
}

#[test]
fn derived_color_spreads_across_the_palette() {
    let mut seen: Vec<TaskBoardProjectColor> = (0..200)
        .map(|index| TaskBoardProjectColor::derived(&format!("project-{index:032x}")))
        .collect();
    seen.sort_unstable_by_key(|color| color.as_str());
    seen.dedup();
    assert!(
        seen.len() > TaskBoardProjectColor::PALETTE.len() / 2,
        "derived colors collapsed onto {} of {} palette entries",
        seen.len(),
        TaskBoardProjectColor::PALETTE.len()
    );
}

#[test]
fn unknown_wire_name_does_not_parse() {
    assert_eq!(TaskBoardProjectColor::parse("chartreuse"), None);
    assert_eq!(TaskBoardProjectColor::parse(""), None);
    assert_eq!(TaskBoardProjectColor::parse("BLUE"), None);
}

use serde::{Deserialize, Serialize};

use super::project_color::TaskBoardProjectColor;

/// The outline a project's mark is drawn in. Colour alone runs out: past the
/// palette two projects must share one, and a second channel is what keeps the
/// pair apart. Shape also survives colour blindness and small sizes, which
/// colour on its own does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardProjectShape {
    Circle,
    Square,
    Triangle,
    Diamond,
    Pentagon,
    Hexagon,
}

impl TaskBoardProjectShape {
    /// Allocation order. A circle leads because a board small enough to stay
    /// inside the colour palette wears nothing else, and the shapes after it
    /// are ordered by how quickly they read at the size of a card mark.
    pub const SHAPES: [Self; 6] = [
        Self::Circle,
        Self::Square,
        Self::Triangle,
        Self::Diamond,
        Self::Hexagon,
        Self::Pentagon,
    ];

    /// What a project wears while the board still fits inside the palette, and
    /// what an unreadable stored shape falls back to.
    pub const DEFAULT: Self = Self::Circle;

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Circle => "circle",
            Self::Square => "square",
            Self::Triangle => "triangle",
            Self::Diamond => "diamond",
            Self::Pentagon => "pentagon",
            Self::Hexagon => "hexagon",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Self::SHAPES.into_iter().find(|shape| shape.as_str() == value)
    }

    /// The shape an organization wears when its stored one cannot be read.
    ///
    /// Seeded by organization rather than project so the two repositories of
    /// one owner still land together, and stable across restarts for the same
    /// reason [`TaskBoardProjectColor::derived`] is: past the palette this is
    /// the only channel telling two same-coloured projects apart, and falling
    /// back to one shared default would collapse it exactly when it matters.
    #[must_use]
    pub fn derived(seed: &str) -> Self {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in seed.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        let shapes_len = u64::try_from(Self::SHAPES.len()).unwrap_or(1);
        let index = usize::try_from(hash % shapes_len).unwrap_or(0);
        Self::SHAPES[index]
    }
}

/// Whether a board of this size still has a spare colour for one more project.
///
/// Below the threshold every project is told apart by colour alone and they all
/// wear the default shape. The moment the palette cannot cover the board, shape
/// starts carrying the organization so the pairs that now share a colour still
/// differ somewhere.
#[must_use]
pub fn colors_alone_suffice(project_count: usize) -> bool {
    project_count <= TaskBoardProjectColor::PALETTE.len()
}

/// The organization half of a project slug: the owner in `owner/repository`,
/// and the whole slug when it carries no owner.
///
/// Shape is assigned per organization rather than per project on purpose. Two
/// repositories from one owner are usually two views of the same work, so a
/// shared outline groups them and the colour still separates them.
#[must_use]
pub fn organization_of(slug: &str) -> &str {
    slug.split_once('/').map_or(slug, |(owner, _)| owner)
}

/// The next shape to hand out, given the ones organizations already hold.
#[must_use]
pub fn allocate(taken: &[TaskBoardProjectShape]) -> TaskBoardProjectShape {
    let mut chosen = TaskBoardProjectShape::SHAPES[0];
    let mut fewest = usize::MAX;
    for shape in TaskBoardProjectShape::SHAPES {
        let held = taken.iter().filter(|other| **other == shape).count();
        // Strictly fewer, so a tie leaves the earlier entry in place and the
        // order in `SHAPES` decides what a crowded board looks like.
        if held < fewest {
            chosen = shape;
            fewest = held;
        }
    }
    chosen
}

#[cfg(test)]
mod tests;

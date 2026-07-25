use serde::{Deserialize, Serialize};

/// The mark a card wears to say which project its work came from. A closed
/// palette rather than a free color: the board's guarantee is that two
/// projects look different, and that is only checkable against a known set.
///
/// The names are plain colors rather than the app's theme token names, so the
/// wire format does not pin the client to one theme's vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardProjectColor {
    Blue,
    Green,
    Purple,
    Amber,
    Teal,
    Pink,
    Red,
    Mint,
    Sky,
    Warm,
    Graphite,
}

impl TaskBoardProjectColor {
    /// Allocation order, not merely the set. The first projects on a board get
    /// the most separable colors, and red arrives late because a red mark on
    /// a card reads as a warning before it reads as an identity.
    pub const PALETTE: [Self; 11] = [
        Self::Blue,
        Self::Green,
        Self::Purple,
        Self::Amber,
        Self::Teal,
        Self::Pink,
        Self::Red,
        Self::Mint,
        Self::Sky,
        Self::Warm,
        Self::Graphite,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Blue => "blue",
            Self::Green => "green",
            Self::Purple => "purple",
            Self::Amber => "amber",
            Self::Teal => "teal",
            Self::Pink => "pink",
            Self::Red => "red",
            Self::Mint => "mint",
            Self::Sky => "sky",
            Self::Warm => "warm",
            Self::Graphite => "graphite",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Self::PALETTE
            .into_iter()
            .find(|color| color.as_str() == value)
    }

    /// A color for a project whose stored one is missing or names a palette
    /// entry this build no longer has.
    #[must_use]
    pub fn derived(seed: &str) -> Self {
        // FNV-1a rather than the standard hasher, whose output is explicitly
        // not stable between builds or processes. A project that changed
        // color when the daemon restarted would lose the one property this
        // fallback exists to keep.
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in seed.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        let palette_len = u64::try_from(Self::PALETTE.len()).unwrap_or(1);
        let index = usize::try_from(hash % palette_len).unwrap_or(0);
        Self::PALETTE[index]
    }
}

/// The next color to hand out, given the ones projects already hold.
///
/// Callers pass every color in use rather than a set, because past exhaustion
/// the choice depends on how many projects hold each one.
#[must_use]
pub fn allocate(taken: &[TaskBoardProjectColor]) -> TaskBoardProjectColor {
    let mut chosen = TaskBoardProjectColor::PALETTE[0];
    let mut fewest = usize::MAX;
    for color in TaskBoardProjectColor::PALETTE {
        let held = taken.iter().filter(|other| **other == color).count();
        // Strictly fewer, so a tie leaves the earlier palette entry in place
        // and the order in `PALETTE` decides what a new board looks like.
        if held < fewest {
            chosen = color;
            fewest = held;
        }
    }
    chosen
}

#[cfg(test)]
mod tests;

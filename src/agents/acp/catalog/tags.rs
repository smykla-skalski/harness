//! Well-known capability-tag values for ACP descriptors.
//!
//! [`CapabilityTag`] is a plain `String` alias. The catalog is intentionally
//! open: any agent can advertise a tag the harness has not seen before, and
//! the picker renders unknown tags as plain text. The constants below name
//! the values harness UI, observe, and tests recognise. Promote a new value
//! here only after a real consumer reads it.

/// Free-form capability tag attached to an ACP agent descriptor.
///
/// Plain alias rather than a newtype: today nothing dispatches on the type,
/// every comparison is a string compare, and the wire format is the string.
/// Promote to a newtype the day a method actually lives on it.
pub type CapabilityTag = String;

/// Agent reads files via ACP `fs/read_text_file`.
pub const FS_READ: &str = "fs.read";
/// Agent writes files via ACP `fs/write_text_file`.
pub const FS_WRITE: &str = "fs.write";
/// Agent spawns terminals via ACP `terminal/create`.
pub const TERMINAL_SPAWN: &str = "terminal.spawn";
/// Agent emits incremental `SessionUpdate` notifications during a turn.
pub const STREAMING: &str = "streaming";
/// Agent supports multi-turn conversation in a single session.
pub const MULTI_TURN: &str = "multi-turn";
/// Agent issues outbound network requests at runtime.
pub const REQUIRES_NETWORK: &str = "requires-network";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_round_trips_through_json() {
        let tag: CapabilityTag = FS_WRITE.to_owned();
        let json = serde_json::to_string(&tag).expect("serialise tag");
        assert_eq!(json, "\"fs.write\"");
        let back: CapabilityTag = serde_json::from_str(&json).expect("deserialise tag");
        assert_eq!(back, tag);
    }

    #[test]
    fn well_known_constants_match_documented_strings() {
        assert_eq!(FS_READ, "fs.read");
        assert_eq!(FS_WRITE, "fs.write");
        assert_eq!(TERMINAL_SPAWN, "terminal.spawn");
        assert_eq!(STREAMING, "streaming");
        assert_eq!(MULTI_TURN, "multi-turn");
        assert_eq!(REQUIRES_NETWORK, "requires-network");
    }
}

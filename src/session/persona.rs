use std::collections::BTreeMap;
use std::sync::LazyLock;

use super::types::{AgentPersona, PersonaSymbol};

static REGISTRY: LazyLock<BTreeMap<&'static str, AgentPersona>> = LazyLock::new(|| {
    let mut map = BTreeMap::new();
    map.insert(
        "code-reviewer",
        AgentPersona {
            identifier: "code-reviewer".into(),
            name: "Code Reviewer".into(),
            symbol: PersonaSymbol::SfSymbol {
                name: "magnifyingglass.circle.fill".into(),
            },
            description: "Reviews code for correctness, style, and potential issues".into(),
        },
    );
    map.insert(
        "test-writer",
        AgentPersona {
            identifier: "test-writer".into(),
            name: "Test Writer".into(),
            symbol: PersonaSymbol::SfSymbol {
                name: "checkmark.circle.fill".into(),
            },
            description: "Writes comprehensive tests for new and existing code".into(),
        },
    );
    map.insert(
        "architect",
        AgentPersona {
            identifier: "architect".into(),
            name: "Architect".into(),
            symbol: PersonaSymbol::SfSymbol {
                name: "building.columns.fill".into(),
            },
            description: "Designs system architecture and evaluates structural decisions".into(),
        },
    );
    map.insert(
        "debugger",
        AgentPersona {
            identifier: "debugger".into(),
            name: "Debugger".into(),
            symbol: PersonaSymbol::SfSymbol {
                name: "ant.fill".into(),
            },
            description: "Investigates and resolves bugs through systematic analysis".into(),
        },
    );
    map.insert(
        "documenter",
        AgentPersona {
            identifier: "documenter".into(),
            name: "Documenter".into(),
            symbol: PersonaSymbol::SfSymbol {
                name: "doc.text.fill".into(),
            },
            description: "Writes and maintains technical documentation".into(),
        },
    );
    map
});

/// Look up a persona by its unique identifier.
///
/// Returns a cloned [`AgentPersona`] if the identifier matches a known
/// persona, or `None` for unknown identifiers.
#[must_use]
pub fn resolve(identifier: &str) -> Option<AgentPersona> {
    REGISTRY.get(identifier).cloned()
}

/// Return all registered personas sorted by identifier.
#[must_use]
pub fn all() -> Vec<AgentPersona> {
    REGISTRY.values().cloned().collect()
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn resolve_known_persona_returns_some() {
        for identifier in [
            "code-reviewer",
            "test-writer",
            "architect",
            "debugger",
            "documenter",
        ] {
            let persona = resolve(identifier);
            assert!(persona.is_some(), "should resolve '{identifier}'");
            assert_eq!(persona.unwrap().identifier, identifier);
        }
    }

    #[test]
    fn resolve_unknown_returns_none() {
        assert!(resolve("nonexistent").is_none());
    }

    #[test]
    fn resolve_empty_string_returns_none() {
        assert!(resolve("").is_none());
    }

    #[test]
    fn all_personas_have_unique_identifiers() {
        let personas = all();
        let identifiers: HashSet<&str> = personas.iter().map(|p| p.identifier.as_str()).collect();
        assert_eq!(
            identifiers.len(),
            personas.len(),
            "all identifiers must be unique"
        );
    }

    #[test]
    fn all_personas_have_nonempty_fields() {
        for persona in all() {
            assert!(
                !persona.identifier.is_empty(),
                "identifier must be non-empty"
            );
            assert!(!persona.name.is_empty(), "name must be non-empty");
            assert!(
                !persona.description.is_empty(),
                "description must be non-empty"
            );
            match &persona.symbol {
                PersonaSymbol::SfSymbol { name } | PersonaSymbol::Asset { name } => {
                    assert!(!name.is_empty(), "symbol name must be non-empty");
                }
            }
        }
    }

    #[test]
    fn all_returns_sorted_by_identifier() {
        let personas = all();
        let identifiers: Vec<&str> = personas.iter().map(|p| p.identifier.as_str()).collect();
        let mut sorted = identifiers.clone();
        sorted.sort_unstable();
        assert_eq!(
            identifiers, sorted,
            "personas should be sorted by identifier"
        );
    }

    #[test]
    fn resolve_returns_cloned_data() {
        let first = resolve("code-reviewer").unwrap();
        let second = resolve("code-reviewer").unwrap();
        assert_eq!(first, second, "both calls should return equal values");
    }
}

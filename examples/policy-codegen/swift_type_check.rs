//! Check that every Swift type a generated module names is actually defined.
//!
//! The emitter resolves a Rust field type by name. When that type lives in a
//! source file the module does not read, the field still emits and the name
//! becomes a reference to nothing. Neither gate catches it: `codegen:check`
//! regenerates and diffs text, so a deterministic dangling name is "no drift",
//! and nothing in the Rust gates compiles Swift. The Monitor build is the only
//! thing that fails, and it fails far away from the cause.
//!
//! Splitting a Rust file to satisfy the source-size cap is how this happens in
//! practice: the types move to a new file, every module that reads the old one
//! keeps emitting references to them, and nothing says so.

use std::collections::BTreeSet;

/// Swift and Foundation names the generated code uses directly.
const SWIFT_BUILTIN_TYPES: &[&str] = &[
    "Bool",
    "Data",
    "Date",
    "Decoder",
    "Double",
    "Encoder",
    "Float",
    "Int",
    "Int32",
    "Int64",
    "Self",
    "String",
    "TimeInterval",
    "UInt",
    "UInt8",
    "UInt16",
    "UInt32",
    "UInt64",
    "URL",
    "UUID",
];

/// Types Swift defines outside codegen that generated modules may name.
///
/// An entry here asserts a hand-written or another module's Swift declaration
/// exists. Adding one is deliberate; a name that belongs to codegen should be
/// emitted instead, by adding its Rust source to the module's `sources`.
/// Every name here was confirmed declared under
/// `apps/harness-monitor/Sources/` when the check landed; keep that true when
/// adding one.
const EXTERNAL_SWIFT_TYPES: &[&str] = &[
    "AckResult",
    "AcpAuthState",
    "AgentStatus",
    "AgentTuiInput",
    "AgentTuiInputSequence",
    "EffortKind",
    "HarnessReviewFileLanguage",
    "ImproverTarget",
    "JSONValue",
    "ManagedAgentKind",
    "PolicyPipelineDocument",
    "ReviewPoint",
    "ReviewVerdict",
    "RuntimeModelTier",
    "SessionRole",
    "SessionSignalStatus",
    "SignalPriority",
    "TaskBoardExternalProvider",
    "TaskBoardExternalSyncAction",
    "TaskBoardGitHubAutomation",
    "TaskBoardGitHubMergeMethod",
    "TaskBoardGitSigningMode",
    "TaskBoardOpenEnum",
    "TaskBoardOrchestratorRunStatus",
    "TaskBoardOrchestratorTickPhase",
    "TaskBoardOrchestratorWorkflow",
    "TaskQueuePolicy",
    "TaskStatus",
];

/// Names a generated module declares.
pub(crate) fn declared_types(generated: &str) -> BTreeSet<String> {
    generated
        .lines()
        .filter_map(declared_on_line)
        .map(str::to_owned)
        .collect()
}

fn declared_on_line(line: &str) -> Option<&str> {
    for keyword in ["public struct ", "public enum ", "public typealias "] {
        if let Some(rest) = line.strip_prefix(keyword) {
            return Some(identifier_prefix(rest));
        }
    }
    None
}

/// Names a generated module references from a field or an associated value.
///
/// Every emitted field appears as a `public var` and every tagged-enum payload
/// as a `case` associated value, so those two positions cover the type names
/// the Swift compiler has to resolve.
pub(crate) fn referenced_types(generated: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for line in generated.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("public var ") {
            collect_property_type(rest, &mut names);
        } else if let Some(rest) = trimmed.strip_prefix("case ") {
            collect_case_types(rest, &mut names);
        }
    }
    names
}

fn collect_property_type(rest: &str, names: &mut BTreeSet<String>) {
    let Some((_, type_expr)) = rest.split_once(": ") else {
        return;
    };
    // `public var id: String { rawValue }` - the computed body is not a type.
    let type_expr = type_expr.split_once(" {").map_or(type_expr, |(head, _)| head);
    collect_type_identifiers(type_expr, names);
}

fn collect_case_types(rest: &str, names: &mut BTreeSet<String>) {
    let Some(start) = rest.find('(') else {
        return;
    };
    let Some(end) = rest.rfind(')') else {
        return;
    };
    for argument in rest[start + 1..end].split(", ") {
        let type_expr = argument.split_once(": ").map_or(argument, |(_, ty)| ty);
        collect_type_identifiers(type_expr, names);
    }
}

/// Pull the base names out of a Swift type expression, unwrapping optionals,
/// arrays and dictionaries.
fn collect_type_identifiers(type_expr: &str, names: &mut BTreeSet<String>) {
    let expr = type_expr.trim().trim_end_matches('?');
    if let Some(inner) = expr.strip_prefix('[').and_then(|e| e.strip_suffix(']')) {
        if let Some((key, value)) = inner.split_once(": ") {
            collect_type_identifiers(key, names);
            collect_type_identifiers(value, names);
        } else {
            collect_type_identifiers(inner, names);
        }
        return;
    }
    let name = identifier_prefix(expr);
    if !name.is_empty() && name.starts_with(char::is_uppercase) {
        names.insert(name.to_owned());
    }
}

fn identifier_prefix(text: &str) -> &str {
    let end = text
        .find(|character: char| !character.is_alphanumeric() && character != '_')
        .unwrap_or(text.len());
    &text[..end]
}

/// Referenced names that nothing defines: not emitted by any module, not a
/// Swift builtin, and not declared external.
pub(crate) fn undefined_types(
    generated: &str,
    declared_anywhere: &BTreeSet<String>,
) -> BTreeSet<String> {
    referenced_types(generated)
        .into_iter()
        .filter(|name| {
            !declared_anywhere.contains(name)
                && !SWIFT_BUILTIN_TYPES.contains(&name.as_str())
                && !EXTERNAL_SWIFT_TYPES.contains(&name.as_str())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn declared_set(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn finds_declarations_of_each_emitted_shape() {
        let generated = "public struct AcpMcpEnvVariable: Codable {\n\
                         public enum AcpMcpServer: Codable, Equatable, Sendable {\n\
                         public typealias PolicyScenario = HarnessMonitorPolicyModels.PolicyScenario\n";

        assert_eq!(
            declared_types(generated),
            declared_set(&["AcpMcpEnvVariable", "AcpMcpServer", "PolicyScenario"])
        );
    }

    #[test]
    fn unwraps_optionals_arrays_and_dictionaries() {
        let generated = "  public var servers: [AcpMcpServer]\n\
                           public var title: String?\n\
                           public var headers: [String: AcpMcpHttpHeader]\n\
                           public var id: String { rawValue }\n";

        assert_eq!(
            referenced_types(generated),
            declared_set(&["AcpMcpHttpHeader", "AcpMcpServer", "String"])
        );
    }

    #[test]
    fn reads_tagged_enum_associated_values() {
        let generated = "  case stdio(name: String, env: [AcpMcpEnvVariable])\n  case unknown(String)\n";

        assert_eq!(
            referenced_types(generated),
            declared_set(&["AcpMcpEnvVariable", "String"])
        );
    }

    /// The exact regression: a field emitted for a type whose Rust source the
    /// module never read.
    #[test]
    fn reports_a_referenced_type_that_no_module_defines() {
        let generated = "public struct AcpAgentStartRequestWire: Codable {\n  public var mcpServers: [AcpMcpServer]\n}\n";

        assert_eq!(
            undefined_types(generated, &declared_set(&["AcpAgentStartRequestWire"])),
            declared_set(&["AcpMcpServer"])
        );
    }

    #[test]
    fn accepts_a_type_another_module_defines() {
        let generated = "public struct ManagedAgentSnapshotWire: Codable {\n  public var acp: AcpAgentSnapshotWire?\n}\n";

        assert!(
            undefined_types(
                generated,
                &declared_set(&["AcpAgentSnapshotWire", "ManagedAgentSnapshotWire"])
            )
            .is_empty()
        );
    }
}

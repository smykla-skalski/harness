#![allow(
    clippy::doc_markdown,
    reason = "generator documentation intentionally uses many Rust and Swift identifiers"
)]

//! Rust -> Swift wire-type generator for the policy-canvas pilot.
//!
//! Reads the policy-graph Rust types and emits Codable Swift that round-trips
//! the serde wire format. Built in-house: specta-swift 0.0.3 stack-overflows on
//! internally-tagged enums and typeshare cannot express the adjacently-tagged
//! enums later increments need. Run with:
//! `mise run codegen`.
//!
//! Memory discipline: every emitter appends into one caller-owned `String`
//! buffer via `write!` (no per-item temporaries) and the case helpers pre-size
//! their single allocation. Each module still parses one source file at a time,
//! so only that file's AST is ever live, but the driver holds every rendered
//! module at once: a type one module references may be emitted by another, and
//! [`swift_type_check`] can only tell a dangling name from a cross-module one
//! after all of them exist.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

// The crate root sits in `examples/`, so a bare `mod` would land beside it and
// look like another example target. Keep the file in this bin's own directory.
#[path = "policy-codegen/swift_type_check.rs"]
mod swift_type_check;

use syn::{
    Attribute, Expr, Fields, FieldsNamed, GenericArgument, Item, ItemEnum, ItemStruct, Lit,
    PathArguments, Stmt, Type, Variant,
};

/// A Swift `String`-backed enum generated from a fieldless, `rename_all =
/// "snake_case"` Rust enum. Each case pairs the Swift case name with its serde
/// raw value.
struct SwiftStringEnum {
    name: String,
    cases: Vec<SwiftStringEnumCase>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SwiftStringEnumCase {
    name: String,
    raw_value: String,
    aliases: Vec<String>,
}

/// A generated Swift struct field with its wire `CodingKey`, the decoder
/// fallback (`decode_default`, kept strict so it never tolerates a field serde
/// itself requires), and the memberwise-initializer default (`init_default`,
/// which can additionally default to a nested `Default` struct's zero value).
struct SwiftField {
    property: String,
    coding_key: String,
    type_name: String,
    optional: bool,
    decode_default: Option<String>,
    init_default: Option<String>,
}

/// A generated Swift `Codable` struct mirroring a Rust wire struct. Per-field
/// memberwise-initializer defaults are resolved during the build phase (see
/// `SwiftField::init_default`), so the Swift type stays callable with no
/// arguments exactly when its Rust counterpart derives `Default`.
struct SwiftStruct {
    name: String,
    fields: Vec<SwiftField>,
}

/// The payload shape of an internally-tagged enum variant.
enum VariantPayload {
    Unit,
    Fields(Vec<SwiftField>),
    Newtype(String),
}

/// One variant of an internally-tagged (`#[serde(tag = ...)]`) enum.
struct SwiftTaggedVariant {
    case_name: String,
    raw_tag: String,
    payload: VariantPayload,
}

/// A generated Swift enum mirroring a Rust tagged enum: associated values inline
/// (no `indirect` boxing) with a discriminator-switched Codable. `content` is
/// `None` for an internally-tagged enum (`#[serde(tag = ...)]`, payload fields
/// flattened beside the tag) and `Some(key)` for an adjacently-tagged enum
/// (`#[serde(tag = ..., content = ...)]`, payload nested under that key).
struct SwiftTaggedEnum {
    name: String,
    tag: String,
    content: Option<String>,
    variants: Vec<SwiftTaggedVariant>,
}

/// Emit a `String`-backed Codable Swift enum into `out`.
fn emit_string_enum(out: &mut String, spec: &SwiftStringEnum) {
    writeln!(
        out,
        "public enum {}: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {{",
        spec.name
    )
    .unwrap();
    for case in &spec.cases {
        writeln!(out, "  case {} = \"{}\"", case.name, case.raw_value).unwrap();
    }
    out.push_str("\n  public var id: String { rawValue }\n");
    if spec.cases.iter().any(|case| !case.aliases.is_empty()) {
        emit_string_enum_codable(out, spec);
    }
    out.push_str("}\n");
}

fn emit_string_enum_codable(out: &mut String, spec: &SwiftStringEnum) {
    out.push_str("\n  public init(from decoder: Decoder) throws {\n");
    out.push_str("    let container = try decoder.singleValueContainer()\n");
    out.push_str("    let rawValue = try container.decode(String.self)\n");
    out.push_str("    switch rawValue {\n");
    for case in &spec.cases {
        write!(out, "    case \"{}\"", case.raw_value).unwrap();
        for alias in &case.aliases {
            write!(out, ", \"{alias}\"").unwrap();
        }
        writeln!(out, ": self = .{}", case.name).unwrap();
    }
    writeln!(
        out,
        "    default: throw DecodingError.dataCorruptedError(in: container, debugDescription: \"Cannot initialize {} from invalid String value \\(rawValue)\")",
        spec.name
    )
    .unwrap();
    out.push_str("    }\n  }\n\n");
    out.push_str("  public func encode(to encoder: Encoder) throws {\n");
    out.push_str("    var container = encoder.singleValueContainer()\n");
    out.push_str("    try container.encode(rawValue)\n");
    out.push_str("  }\n");
}

/// Wire enums the app keeps forward-compatible: an unrecognized daemon value
/// decodes to `.unknown(String)` instead of throwing. Listed by Swift type
/// name; every other fieldless enum emits as a closed `String`-backed enum. The
/// app owns this list because the Rust enums are closed - the openness is a
/// Swift-side resilience choice.
const OPEN_STRING_ENUMS: &[&str] = &[
    // reviews/enums.rs: the GitHub review wire enums the app adopts directly
    // (generated, bare-named), every one forward-compatible against an
    // unrecognized GitHub value. ReviewAuthorAssociation is the lone exception
    // (adopted closed, since its consumers switch over a real `other` variant
    // with no unknown arm), so it is not in this list.
    "ReviewPullRequestState",
    "ReviewMergeableState",
    "ReviewReviewStatus",
    "ReviewCheckStatus",
    "ReviewCheckRunStatus",
    "ReviewCheckConclusion",
    "ReviewReviewEventState",
    "ReviewActionKind",
    "ReviewActionOutcome",
    "ReviewActionPreviewKind",
    // reviews leaves: split (suffixed) open enum, so the Wire name is listed.
    "ReviewsBodyUpdateOutcomeWire",
    // observe::types classification: forward-compatible against an evolving
    // harness taxonomy (IssueCode grows as new issue families land) and a
    // zero-regression match for the String fields they replace app-side.
    "IssueSeverity",
    "IssueCategory",
    "IssueCode",
    "FixSafety",
    // task_board types.rs foundation enums adopted as the app's open TaskBoardOpenEnum
    // conformers (listed by Swift name: AgentMode is renamed to TaskBoardAgentMode).
    // Both already model an unknown(String) catch-all app-side; TaskBoardPriority stays
    // closed (default emit). Their .title moves to a hand extension.
    "TaskBoardStatus",
    "TaskBoardAgentMode",
];

/// Emit an open Swift enum conforming to `TaskBoardOpenEnum` (which supplies the
/// single-value `Codable` over `rawValue`). Known variants plus a
/// `.unknown(String)` fallback, with `allCases` listing only the known cases.
fn emit_open_enum(out: &mut String, spec: &SwiftStringEnum) {
    // The `.unknown(String)` catch-all subsumes any explicit Rust variant named
    // `Unknown`: a wire value of "unknown" decodes to `.unknown("unknown")`.
    // Emitting both a `case unknown` and the `case unknown(String)` catch-all
    // is an invalid redeclaration, so drop the known case and let the catch-all
    // own it - matching the hand-written open enums.
    let cases: Vec<&SwiftStringEnumCase> = spec
        .cases
        .iter()
        .filter(|case| case.name != "unknown")
        .collect();
    writeln!(
        out,
        "public enum {}: TaskBoardOpenEnum, CaseIterable, Identifiable {{",
        spec.name
    )
    .unwrap();
    for case in &cases {
        writeln!(out, "  case {}", case.name).unwrap();
    }
    out.push_str("  case unknown(String)\n\n");
    let known = cases
        .iter()
        .map(|case| format!(".{}", case.name))
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(out, "  public static let allCases: [Self] = [{known}]\n").unwrap();
    out.push_str("  public var rawValue: String {\n    switch self {\n");
    for case in &cases {
        writeln!(out, "    case .{}: \"{}\"", case.name, case.raw_value).unwrap();
    }
    out.push_str("    case .unknown(let raw): raw\n    }\n  }\n\n");
    out.push_str("  public init(rawValue: String) {\n    switch rawValue {\n");
    for case in &cases {
        write!(out, "    case \"{}\"", case.raw_value).unwrap();
        for alias in &case.aliases {
            write!(out, ", \"{alias}\"").unwrap();
        }
        writeln!(out, ": self = .{}", case.name).unwrap();
    }
    out.push_str("    default: self = .unknown(rawValue)\n    }\n  }\n\n");
    out.push_str("  public var id: String { rawValue }\n");
    out.push_str("}\n");
}

/// Emit a Codable Swift struct with a memberwise initializer, a decoder that
/// applies wire defaults, and `CodingKeys` mapping camelCase to snake_case wire
/// names. Everything appends into `out`.
fn emit_struct(out: &mut String, spec: &SwiftStruct) {
    writeln!(
        out,
        "public struct {}: Codable, Equatable, Sendable {{",
        spec.name
    )
    .unwrap();
    for field in &spec.fields {
        out.push_str("  public var ");
        out.push_str(&field.property);
        out.push_str(": ");
        push_type(out, field);
        out.push('\n');
    }

    out.push('\n');
    emit_memberwise_init(out, spec);

    if spec
        .fields
        .iter()
        .any(|field| field.decode_default.is_some())
    {
        out.push('\n');
        emit_decoder(out, spec);
    }

    if !spec.fields.is_empty() {
        out.push('\n');
        emit_coding_keys(out, spec);
    }
    out.push_str("}\n");
}

/// Emit a Swift wrapper for a serde-transparent `String` newtype: a
/// `RawRepresentable` value type that round-trips as the bare string and is
/// usable as a dictionary key, a sortable value, and a string literal. The
/// non-failable `init(rawValue:)` satisfies `RawRepresentable`, and the explicit
/// single-value `Codable` keeps the wire form identical to a plain `String`.
fn emit_newtype(out: &mut String, name: &str) {
    writeln!(
        out,
        "public struct {name}: RawRepresentable, Codable, Hashable, Sendable, Comparable, \
         ExpressibleByStringLiteral, CustomStringConvertible {{"
    )
    .unwrap();
    out.push_str("  public let rawValue: String\n");
    out.push_str("  public init(rawValue: String) {\n    self.rawValue = rawValue\n  }\n");
    out.push_str("  public init(_ rawValue: String) {\n    self.rawValue = rawValue\n  }\n");
    out.push_str("  public init(stringLiteral value: String) {\n    self.rawValue = value\n  }\n");
    out.push_str("  public init(from decoder: Decoder) throws {\n");
    out.push_str("    rawValue = try decoder.singleValueContainer().decode(String.self)\n");
    out.push_str("  }\n");
    out.push_str("  public func encode(to encoder: Encoder) throws {\n");
    out.push_str("    var container = encoder.singleValueContainer()\n");
    out.push_str("    try container.encode(rawValue)\n");
    out.push_str("  }\n");
    out.push_str("  public var description: String {\n    rawValue\n  }\n");
    out.push_str("  public static func < (lhs: Self, rhs: Self) -> Bool {\n");
    out.push_str("    lhs.rawValue < rhs.rawValue\n");
    out.push_str("  }\n");
    out.push_str("}\n");
}

/// Append a field's Swift type, including the trailing `?` for optionals.
fn push_type(out: &mut String, field: &SwiftField) {
    out.push_str(&field.type_name);
    if field.optional {
        out.push('?');
    }
}

/// Emit the public memberwise initializer, defaulting optionals to `nil` and
/// collection fields to their wire default.
fn emit_memberwise_init(out: &mut String, spec: &SwiftStruct) {
    out.push_str("  public init(");
    for (index, field) in spec.fields.iter().enumerate() {
        if index != 0 {
            out.push_str(", ");
        }
        out.push_str(&field.property);
        out.push_str(": ");
        push_type(out, field);
        if let Some(default) = &field.init_default {
            out.push_str(" = ");
            out.push_str(default);
        }
    }
    out.push_str(") {\n");
    for field in &spec.fields {
        writeln!(out, "    self.{0} = {0}", field.property).unwrap();
    }
    out.push_str("  }\n");
}

/// The default value for a field in the memberwise initializer: `nil` for
/// optionals, the decode default when present, or - when the owning struct
/// derives `Default` - the field type's zero value. The zero value is a
/// primitive/array literal, or `TypeName()` when the field's own type is a
/// `Default`-deriving struct, so the Swift type stays callable with no
/// arguments exactly when its Rust counterpart is. This is resolved at build
/// time because only there is the `Default`-deriving struct set in scope; it
/// never feeds the decoder, which stays strict about fields serde requires.
fn field_init_default(
    optional: bool,
    decode_default: Option<&str>,
    type_name: &str,
    rust_ident: Option<&str>,
    derives_default: bool,
    symbols: &SymbolTable,
) -> Option<String> {
    if optional {
        return Some("nil".to_string());
    }
    if let Some(default) = decode_default {
        return Some(default.to_string());
    }
    if !derives_default {
        return None;
    }
    if let Some(zero) = zero_value(type_name) {
        return Some(zero);
    }
    // structs_with_default is keyed by the Rust name; type_name may be suffixed.
    if rust_ident.is_some_and(|ident| symbols.structs_with_default.contains(ident)) {
        return Some(format!("{type_name}()"));
    }
    None
}

/// Emit a decoder that tolerates absent optional and defaulted wire fields.
fn emit_decoder(out: &mut String, spec: &SwiftStruct) {
    out.push_str("  public init(from decoder: Decoder) throws {\n");
    out.push_str("    let container = try decoder.container(keyedBy: CodingKeys.self)\n");
    for field in &spec.fields {
        if field.optional {
            writeln!(
                out,
                "    {0} = try container.decodeIfPresent({1}.self, forKey: .{0})",
                field.property, field.type_name
            )
            .unwrap();
        } else if let Some(default) = &field.decode_default {
            writeln!(
                out,
                "    {0} = try container.decodeIfPresent({1}.self, forKey: .{0}) ?? {2}",
                field.property, field.type_name, default
            )
            .unwrap();
        } else {
            writeln!(
                out,
                "    {0} = try container.decode({1}.self, forKey: .{0})",
                field.property, field.type_name
            )
            .unwrap();
        }
    }
    out.push_str("  }\n");
}

/// Emit `CodingKeys`, renaming to the snake_case wire key only when it differs.
fn emit_coding_keys(out: &mut String, spec: &SwiftStruct) {
    out.push_str("  enum CodingKeys: String, CodingKey {\n");
    for field in &spec.fields {
        if field.property == field.coding_key {
            writeln!(out, "    case {}", field.property).unwrap();
        } else {
            writeln!(
                out,
                "    case {} = \"{}\"",
                field.property, field.coding_key
            )
            .unwrap();
        }
    }
    out.push_str("  }\n");
}

/// Emit an internally-tagged Codable Swift enum: inline associated-value cases,
/// a shared `CodingKeys`, a discriminator-switched decoder, and an encoder that
/// re-inlines newtype payloads alongside the tag.
fn emit_tagged_enum(out: &mut String, spec: &SwiftTaggedEnum) {
    // An internally-tagged enum whose variants are all unit (e.g. the evidence
    // predicate) has no associated values, so Swift can synthesize CaseIterable
    // and Hashable - the app drives `Picker`s (which need a Hashable selection)
    // off it.
    let all_unit = spec
        .variants
        .iter()
        .all(|variant| matches!(variant.payload, VariantPayload::Unit));
    let conformances = if all_unit {
        "Codable, Equatable, Hashable, Sendable, CaseIterable"
    } else {
        "Codable, Equatable, Sendable"
    };
    writeln!(out, "public enum {}: {} {{", spec.name, conformances).unwrap();
    for variant in &spec.variants {
        emit_variant_case(out, variant);
    }
    out.push('\n');
    emit_tagged_coding_keys(out, spec);
    out.push('\n');
    emit_tagged_decoder(out, spec);
    out.push('\n');
    emit_tagged_encoder(out, spec);
    out.push_str("}\n");
}

fn emit_variant_case(out: &mut String, variant: &SwiftTaggedVariant) {
    out.push_str("  case ");
    out.push_str(&variant.case_name);
    match &variant.payload {
        VariantPayload::Unit => {}
        VariantPayload::Fields(fields) => {
            out.push('(');
            for (index, field) in fields.iter().enumerate() {
                if index != 0 {
                    out.push_str(", ");
                }
                out.push_str(&field.property);
                out.push_str(": ");
                push_type(out, field);
            }
            out.push(')');
        }
        VariantPayload::Newtype(inner) => {
            out.push('(');
            out.push_str(inner);
            out.push(')');
        }
    }
    out.push('\n');
}

fn emit_tagged_coding_keys(out: &mut String, spec: &SwiftTaggedEnum) {
    out.push_str("  enum CodingKeys: String, CodingKey {\n");
    writeln!(out, "    case {}", spec.tag).unwrap();
    if let Some(content) = &spec.content {
        writeln!(out, "    case {content}").unwrap();
    }
    let mut seen: Vec<&str> = Vec::new();
    for variant in &spec.variants {
        let VariantPayload::Fields(fields) = &variant.payload else {
            continue;
        };
        for field in fields {
            if seen.contains(&field.coding_key.as_str()) {
                continue;
            }
            seen.push(field.coding_key.as_str());
            if field.property == field.coding_key {
                writeln!(out, "    case {}", field.property).unwrap();
            } else {
                writeln!(
                    out,
                    "    case {} = \"{}\"",
                    field.property, field.coding_key
                )
                .unwrap();
            }
        }
    }
    out.push_str("  }\n");
}

fn emit_tagged_decoder(out: &mut String, spec: &SwiftTaggedEnum) {
    out.push_str("  public init(from decoder: Decoder) throws {\n");
    out.push_str("    let container = try decoder.container(keyedBy: CodingKeys.self)\n");
    writeln!(
        out,
        "    let {0} = try container.decode(String.self, forKey: .{0})",
        spec.tag
    )
    .unwrap();
    writeln!(out, "    switch {} {{", spec.tag).unwrap();
    for variant in &spec.variants {
        writeln!(out, "    case \"{}\":", variant.raw_tag).unwrap();
        emit_variant_decode(out, variant, spec.content.as_deref());
    }
    out.push_str("    default:\n");
    writeln!(
        out,
        "      throw DecodingError.dataCorruptedError(forKey: .{0}, in: container, debugDescription: \"unknown {1} {0} \\({0})\")",
        spec.tag, spec.name
    )
    .unwrap();
    out.push_str("    }\n");
    out.push_str("  }\n");
}

fn emit_variant_decode(out: &mut String, variant: &SwiftTaggedVariant, content: Option<&str>) {
    match &variant.payload {
        VariantPayload::Unit => {
            writeln!(out, "      self = .{}", variant.case_name).unwrap();
        }
        VariantPayload::Fields(_) if content.is_some() => {
            panic!(
                "adjacently-tagged struct variant `{}` is out of scope; only newtype/unit variants are supported",
                variant.case_name
            );
        }
        VariantPayload::Fields(fields) => {
            out.push_str("      self = .");
            out.push_str(&variant.case_name);
            out.push('(');
            for (index, field) in fields.iter().enumerate() {
                if index != 0 {
                    out.push_str(", ");
                }
                out.push_str(&field.property);
                out.push_str(": ");
                push_decode_rhs(out, field);
            }
            out.push_str(")\n");
        }
        VariantPayload::Newtype(inner) => match content {
            Some(content) => writeln!(
                out,
                "      self = .{}(try container.decode({}.self, forKey: .{}))",
                variant.case_name, inner, content
            )
            .unwrap(),
            None => writeln!(
                out,
                "      self = .{}(try {}(from: decoder))",
                variant.case_name, inner
            )
            .unwrap(),
        },
    }
}

/// Append the right-hand side of a field decode, tolerating absent optionals and
/// defaulted collections.
fn push_decode_rhs(out: &mut String, field: &SwiftField) {
    if field.optional {
        write!(
            out,
            "try container.decodeIfPresent({}.self, forKey: .{})",
            field.type_name, field.property
        )
        .unwrap();
    } else if let Some(default) = &field.decode_default {
        write!(
            out,
            "try container.decodeIfPresent({}.self, forKey: .{}) ?? {}",
            field.type_name, field.property, default
        )
        .unwrap();
    } else {
        write!(
            out,
            "try container.decode({}.self, forKey: .{})",
            field.type_name, field.property
        )
        .unwrap();
    }
}

fn emit_tagged_encoder(out: &mut String, spec: &SwiftTaggedEnum) {
    out.push_str("  public func encode(to encoder: Encoder) throws {\n");
    out.push_str("    var container = encoder.container(keyedBy: CodingKeys.self)\n");
    out.push_str("    switch self {\n");
    for variant in &spec.variants {
        emit_variant_encode(out, variant, &spec.tag, spec.content.as_deref());
    }
    out.push_str("    }\n");
    out.push_str("  }\n");
}

fn emit_variant_encode(
    out: &mut String,
    variant: &SwiftTaggedVariant,
    tag: &str,
    content: Option<&str>,
) {
    match &variant.payload {
        VariantPayload::Unit => {
            writeln!(out, "    case .{}:", variant.case_name).unwrap();
            writeln!(
                out,
                "      try container.encode(\"{}\", forKey: .{})",
                variant.raw_tag, tag
            )
            .unwrap();
        }
        VariantPayload::Fields(_) if content.is_some() => {
            panic!(
                "adjacently-tagged struct variant `{}` is out of scope; only newtype/unit variants are supported",
                variant.case_name
            );
        }
        VariantPayload::Fields(fields) => {
            out.push_str("    case .");
            out.push_str(&variant.case_name);
            out.push('(');
            for (index, field) in fields.iter().enumerate() {
                if index != 0 {
                    out.push_str(", ");
                }
                out.push_str("let ");
                out.push_str(&field.property);
            }
            out.push_str("):\n");
            writeln!(
                out,
                "      try container.encode(\"{}\", forKey: .{})",
                variant.raw_tag, tag
            )
            .unwrap();
            for field in fields {
                writeln!(
                    out,
                    "      try container.encode({0}, forKey: .{0})",
                    field.property
                )
                .unwrap();
            }
        }
        VariantPayload::Newtype(_inner) => {
            writeln!(out, "    case .{}(let value):", variant.case_name).unwrap();
            writeln!(
                out,
                "      try container.encode(\"{}\", forKey: .{})",
                variant.raw_tag, tag
            )
            .unwrap();
            match content {
                Some(content) => {
                    writeln!(out, "      try container.encode(value, forKey: .{content})").unwrap();
                }
                None => out.push_str("      try value.encode(to: encoder)\n"),
            }
        }
    }
}

/// Lowercase the first character: a Rust PascalCase enum variant to a Swift
/// camelCase case name (`DryRun` -> `dryRun`).
fn pascal_to_camel(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut chars = name.chars();
    if let Some(first) = chars.next() {
        out.extend(first.to_lowercase());
        out.push_str(chars.as_str());
    }
    out
}

/// A Rust PascalCase enum variant to its serde `rename_all = "snake_case"` wire
/// value (`DryRun` -> `dry_run`).
fn pascal_to_snake(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 8);
    for (index, ch) in name.chars().enumerate() {
        if ch.is_uppercase() {
            if index != 0 {
                out.push('_');
            }
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

/// The serde wire string for a PascalCase enum variant under the container's
/// `rename_all`: snake_case by default, camelCase when the enum sets
/// `rename_all = "camelCase"` (`SpeechToText` -> `speechToText`).
fn variant_wire_value(variant: &str, rename_all: Option<&str>) -> String {
    match rename_all {
        Some("camelCase") => pascal_to_camel(variant),
        _ => pascal_to_snake(variant),
    }
}

/// A snake_case Rust field name to a Swift camelCase property
/// (`input_ports` -> `inputPorts`).
fn snake_to_camel(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut capitalize_next = false;
    for ch in name.chars() {
        if ch == '_' {
            capitalize_next = true;
        } else if capitalize_next {
            out.extend(ch.to_uppercase());
            capitalize_next = false;
        } else {
            out.push(ch);
        }
    }
    out
}

/// Swift reserved words that must be backtick-escaped to serve as identifiers.
const SWIFT_KEYWORDS: &[&str] = &[
    "associatedtype",
    "class",
    "deinit",
    "enum",
    "extension",
    "fileprivate",
    "func",
    "import",
    "init",
    "inout",
    "internal",
    "let",
    "open",
    "operator",
    "private",
    "protocol",
    "public",
    "rethrows",
    "static",
    "struct",
    "subscript",
    "typealias",
    "var",
    "break",
    "case",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "fallthrough",
    "for",
    "guard",
    "if",
    "in",
    "repeat",
    "return",
    "switch",
    "where",
    "while",
    "as",
    "catch",
    "false",
    "is",
    "nil",
    "super",
    "self",
    "Self",
    "throw",
    "throws",
    "true",
    "try",
    "Any",
    "_",
];

/// Wrap a Swift reserved word in backticks so it is usable as an identifier;
/// pass any other name through untouched.
fn escape_keyword(ident: String) -> String {
    if SWIFT_KEYWORDS.contains(&ident.as_str()) {
        format!("`{ident}`")
    } else {
        ident
    }
}

/// The Swift type for a Rust wire field, with `Option<T>` lifted into the
/// `optional` flag. Scalars map to exact-width Swift types (`u8` -> `UInt8`)
/// so generated structs stay as small as their Rust originals.
struct SwiftType {
    name: String,
    optional: bool,
}

fn rust_type_to_swift(ty: &Type) -> SwiftType {
    let Type::Path(type_path) = ty else {
        return SwiftType {
            name: "AnyCodable".to_string(),
            optional: false,
        };
    };
    let Some(segment) = type_path.path.segments.last() else {
        return SwiftType {
            name: "AnyCodable".to_string(),
            optional: false,
        };
    };
    let ident = segment.ident.to_string();
    match ident.as_str() {
        "Option" => SwiftType {
            name: first_generic_arg(&segment.arguments)
                .map(rust_type_to_swift)
                .map_or_else(|| "AnyCodable".to_string(), |mapped| mapped.name),
            optional: true,
        },
        "Vec" | "BTreeSet" | "HashSet" => SwiftType {
            name: format!("[{}]", vec_element(&segment.arguments)),
            optional: false,
        },
        "HashMap" | "BTreeMap" => SwiftType {
            name: map_dictionary(&segment.arguments),
            optional: false,
        },
        // Box<T> is transparent on the wire (serde serializes it exactly like
        // T), so unwrap to the inner type's mapping. Used for boxed enum
        // variants like ReviewTimelineEntry::SimpleActorEvent(Box<...>).
        "Box" => first_generic_arg(&segment.arguments).map_or_else(
            || SwiftType {
                name: "AnyCodable".to_string(),
                optional: false,
            },
            rust_type_to_swift,
        ),
        scalar => SwiftType {
            name: map_scalar(scalar),
            optional: false,
        },
    }
}

/// The Swift element type for a `Vec<T>`, carrying through an inner `Option`.
fn vec_element(arguments: &PathArguments) -> String {
    match first_generic_arg(arguments).map(rust_type_to_swift) {
        Some(mapped) if mapped.optional => format!("{}?", mapped.name),
        Some(mapped) => mapped.name,
        None => "AnyCodable".to_string(),
    }
}

/// The Swift dictionary type for a `HashMap<K, V>` / `BTreeMap<K, V>`. JSON
/// object keys are always strings, so the key maps through normally (the wire
/// surface only uses `String` keys) and the value carries through an inner
/// `Option` like `vec_element`.
fn map_dictionary(arguments: &PathArguments) -> String {
    let args = generic_type_args(arguments);
    let key = args
        .first()
        .map_or_else(|| "String".to_string(), |ty| rust_type_to_swift(ty).name);
    let value = match args.get(1).map(|ty| rust_type_to_swift(ty)) {
        Some(mapped) if mapped.optional => format!("{}?", mapped.name),
        Some(mapped) => mapped.name,
        None => "AnyCodable".to_string(),
    };
    format!("[{key}: {value}]")
}

/// The bare type name of a path type - its last segment ident, e.g.
/// `ReviewItemFlags` for `flags: ReviewItemFlags`. `None` for non-path types.
fn type_ident(ty: &Type) -> Option<String> {
    let Type::Path(type_path) = ty else {
        return None;
    };
    type_path
        .path
        .segments
        .last()
        .map(|segment| segment.ident.to_string())
}

/// Every concrete type argument of an angle-bracketed path segment, in order.
fn generic_type_args(arguments: &PathArguments) -> Vec<&Type> {
    let PathArguments::AngleBracketed(bracketed) = arguments else {
        return Vec::new();
    };
    bracketed
        .args
        .iter()
        .filter_map(|arg| match arg {
            GenericArgument::Type(ty) => Some(ty),
            _ => None,
        })
        .collect()
}

/// Rust wire types whose bare Swift name is owned by a hand-written rich app
/// model, so the generated thin type is emitted with a `Wire` suffix (e.g.
/// `HarnessMonitorAuditEvent` -> `HarnessMonitorAuditEventWire`) and the app
/// decodes the wire type then maps it to the model. Empty until a rich-model
/// subsystem migrates; with it empty, every module stays byte-identical.
const WIRE_SUFFIXED_TYPES: &[&str] = &[
    "HarnessMonitorAuditDateRange",
    "HarnessMonitorAuditEventsRequest",
    "HarnessMonitorAuditEvent",
    "HarnessMonitorAuditEventsResponse",
    "AgentTuiSize",
    "AgentTuiLaunchProfile",
    "AgentTuiStatus",
    "AgentTuiStartRequest",
    "AgentTuiResizeRequest",
    "AgentTuiListResponse",
    "AgentTuiSnapshot",
    "TerminalScreenSnapshot",
    "CodexRunMode",
    "CodexRunStatus",
    "CodexApprovalDecision",
    "CodexRunRequest",
    "CodexSteerRequest",
    "CodexApprovalDecisionRequest",
    "CodexRunListResponse",
    "CodexAgentInspectResponse",
    "CodexAgentInspectSnapshot",
    "CodexTranscriptResponse",
    "CodexApprovalRequest",
    "CodexResolvedApproval",
    "CodexRunEvent",
    "CodexRunSnapshot",
    "CodexApprovalRequestedPayload",
    "RoleChangeRequest",
    "AgentRemoveRequest",
    "LeaderTransferRequest",
    "TaskCreateRequest",
    "TaskDeleteRequest",
    "TaskAssignRequest",
    "TaskDropRequest",
    "TaskDropTarget",
    "TaskQueuePolicyRequest",
    "TaskUpdateRequest",
    "TaskCheckpointRequest",
    "SessionEndRequest",
    "SessionArchiveRequest",
    "SignalSendRequest",
    "ObserveSessionRequest",
    "SessionStartRequest",
    "SignalCancelRequest",
    "TaskSubmitForReviewRequest",
    "TaskClaimReviewRequest",
    "TaskSubmitReviewRequest",
    "TaskRespondReviewRequest",
    "TaskArbitrateRequest",
    "ImproverApplyRequest",
    "SessionArchiveResponse",
    "AdoptSessionRequest",
    // reviews leaves (avatar/body_update/file_comment/review_thread_resolve):
    // wire/model split - the hand models live in scattered/mixed Swift files.
    "ReviewsAvatarRequest",
    "ReviewsAvatarResponse",
    "ReviewsBodyUpdateRequest",
    "ReviewsBodyUpdateOutcome",
    "ReviewsBodyUpdateResponse",
    "ReviewsFileCommentKind",
    "ReviewsFileCommentRequest",
    "ReviewsFileCommentResponse",
    "ReviewsReviewThreadResolveRequest",
    "ReviewsReviewThreadResolveResponse",
    // reviews files-core (files/mod.rs + blob.rs + viewed.rs): wire/model split.
    // The hand models live in ReviewFile.swift / +Requests / +Previews (mixed),
    // some renamed (ReviewImageMime -> HarnessReviewImageMime).
    "ReviewsFilesListRequest",
    "ReviewsFilesListResponse",
    "ReviewFile",
    "ReviewFileChangeType",
    "ReviewFileViewedState",
    "ReviewsRateLimitSnapshot",
    "ReviewsFilesPatchRequest",
    "ReviewsFilesPatchResponse",
    "ReviewFileServedBy",
    "ReviewFilePatch",
    "ReviewImageMime",
    "ReviewsFilesBlobRequest",
    "ReviewsFilesBlobResponse",
    "ReviewsFilesViewedRequest",
    "ReviewFilesViewedTarget",
    "ReviewFileViewedOutcome",
    "ReviewFilesViewedResult",
    "ReviewsFilesViewedResponse",
    // reviews files preview + local-clone facade: the preview request/response and
    // the two cross-wire facade types. FilesLargeDiffStrategy is referenced by the
    // preview/patch requests; LocalCloneListEntry is the Settings clones row.
    "ReviewsFilesPreviewRequest",
    "ReviewFilePreview",
    "ReviewsFilesPreviewResponse",
    "FilesLargeDiffStrategy",
    "LocalCloneListEntry",
    // reviews timeline (timeline/types.rs + mod.rs): wire/model split, generated
    // generate-only (decode contract test, no hand mapping). Actor -> ActorWire
    // dodges the Swift `actor` keyword; ReviewTimelineEntry is an internally
    // tagged newtype enum.
    "Actor",
    "ReviewTimelineEntry",
    "IssueCommentEntry",
    "ReviewEntry",
    "ReviewState",
    "ReviewInlineCommentEntry",
    "ReviewThreadEntry",
    "ReviewThreadCommentEntry",
    "CommitEntry",
    "HeadRefForcePushedEntry",
    "SimpleActorEventEntry",
    "SimpleActorEventKind",
    "UnknownEntry",
    "ReviewsTimelineRequest",
    "TimelinePageDirection",
    "ReviewsTimelineResponse",
    "TimelinePageInfo",
    // reviews types.rs core (query/item/check/action/policy surface): generate
    // -only split. ReviewItem/ReviewTarget/ReviewsCapabilitiesResponse flatten
    // their *Flags/*Capabilities structs (inlined). ReviewAuthorAssociation is a
    // bare reference to the adopted closed enum; GitHubMergeMethod is renamed
    // (TYPE_RENAMES).
    "ReviewsQueryRequest",
    "ReviewsRepositoryCatalogRequest",
    "ReviewsRepositoryCatalogResponse",
    "ReviewsPullRequestReference",
    "ReviewsPullRequestResolveRequest",
    "ReviewsPullRequestResolveResponse",
    "ReviewsQueryResponse",
    "ReviewRepositoryLabel",
    "ReviewsSummary",
    "ReviewItemFlags",
    "ReviewItem",
    "ReviewCheck",
    "PullRequestReview",
    "ReviewsApproveRequest",
    "ReviewsMergeRequest",
    "ReviewsRerunChecksRequest",
    "ReviewsLabelRequest",
    "ReviewsAutoRequest",
    "ReviewsPolicySubject",
    "ReviewsPolicyTrigger",
    "ReviewsPolicyRunStatus",
    "ReviewsPolicyStepType",
    "ReviewsPolicyWait",
    "ReviewsPolicyPreviewStep",
    "ReviewsPolicyPreviewRequest",
    "ReviewsPolicyPreviewResponse",
    "ReviewsPolicyRunStartRequest",
    "ReviewsPolicyRunStep",
    "ReviewsPolicyRunResponse",
    "ReviewsPolicyStatusRequest",
    "ReviewsPolicyStatusResponse",
    "ReviewsPolicyHistoryRequest",
    "ReviewsPolicyRunMetrics",
    "ReviewsPolicyTimelineEntry",
    "ReviewsPolicyHistoryResponse",
    "ReviewsCommentRequest",
    "ReviewsRequestReviewRequest",
    "ReviewsActionCapabilities",
    "ReviewsCapabilitiesResponse",
    "ReviewsActionPreviewRequest",
    "ReviewsActionPreviewResponse",
    "ReviewActionPreviewTarget",
    "ReviewsActionResponse",
    "ReviewsCacheClearResponse",
    "ReviewsRefreshRequest",
    "ReviewsRefreshResponse",
    "ReviewsBodyRequest",
    "ReviewsBodyResponse",
    "ReviewTargetFlags",
    "ReviewTarget",
    "ReviewActionResult",
    // websocket transport envelope (protocol/websocket.rs): the 5 self-contained
    // frame types. WsRequest/WsErrorPayload own a Swift hand name (WebSocketProtocol
    // .swift); WsResponse/WsPushEvent/WsChunkFrame have no Swift mirror (the app
    // decodes a unified WsFrame) - all suffixed for a consistent generate-only set.
    "WsRequest",
    "WsResponse",
    "WsErrorPayload",
    "WsPushEvent",
    "WsChunkFrame",
    // session tasks (session/types/tasks.rs): 10 review-flow structs, generate-only.
    // WorkItem is the task-board core; the rest are its nested review state. The 3
    // plain enums (TaskSeverity/TaskSource/ReviewPointState) are adopted generated
    // bare; the 3 legacy-decode enums + ReviewPoint stay bare Swift hand - see
    // SKIP_TYPES.
    "WorkItem",
    "TaskNote",
    "TaskCheckpoint",
    "TaskCheckpointSummary",
    "AwaitingReview",
    "ReviewerEntry",
    "ReviewClaim",
    "Review",
    "ReviewConsensus",
    "ArbitrationOutcome",
    // policy simulate/audit cluster (policy_graph/store.rs): the rich app models
    // (PolicyPipelineSimulationResult/...AuditSummary) keep their flat
    // shape; these *Wire types own the daemon snake_case decode (the validation
    // report nests the generated PolicyGraphValidationIssue, which fixes the
    // node_id/edge_id/node_ids drop when simulate/audit decoded via convertFromSnakeCase).
    "PolicyPipelineSimulatedDecision",
    "PolicyPipelineSimulationResult",
    "PolicyPipelineAuditSummary",
    // summaries.rs health/readiness cluster (allow-listed via SUMMARIES_EMIT_ONLY):
    // self-contained structs over primitives; the rich hand models stay, these
    // own the daemon snake_case decode. generate-only for now.
    "HealthResponse",
    "DaemonControlResponse",
    "LogLevelResponse",
    "SetLogLevelRequest",
    "HostBridgeReconfigureRequest",
    // github diagnostics sub-cluster (GitHubApiDiagnostics + nested rate/cooldown/
    // operation structs); generate-only, GitHubApiDiagnostics is decoded by githubStatus().
    "GitHubApiDiagnostics",
    "GitHubRateBucketDiagnostics",
    "GitHubCooldownDiagnostics",
    "GitHubOperationSpendDiagnostics",
    // observer summary cluster: ObserverSummary/ObserverAgentSessionSummary own a
    // Swift hand name so must take the Wire suffix; ObserverOpenIssue/ObserverActive
    // Worker are suffixed for consistency. They reference the bare observe enums
    // (IssueCode etc.) which the observe module emits unsuffixed in the same Kit module.
    "ObserverSummary",
    "ObserverOpenIssue",
    "ObserverActiveWorker",
    "ObserverAgentSessionSummary",
    // session/types/state.rs: SessionMetrics takes the suffix (hand counts are Int,
    // wire is u32). SessionStatus is NOT suffixed - it is adopted bare.
    "SessionMetrics",
    // session/types/agents.rs leaf + the summaries SessionSummary that nests it:
    // both are structs with a Swift hand mirror, so they take the Wire suffix
    // (generate-only until SessionSummary reroutes off convertFromSnakeCase).
    "PendingLeaderTransfer",
    "SessionSummary",
    // agent tool-activity cluster + the hooks AskUserQuestion leaf it nests. All take
    // the Wire suffix (AgentPendingUserPrompt/AgentToolActivitySummary have same-named
    // hand mirrors; the hooks types are renamed hand-side, suffixed for consistency).
    "AskUserQuestionOption",
    "AskUserQuestionPrompt",
    "AgentPendingUserPrompt",
    "AgentToolActivitySummary",
    // project/worktree rollup structs (same-named Swift hand mirrors).
    "WorktreeSummary",
    "ProjectSummary",
    // timeline pagination cursor + window request (same-named Swift hand mirrors).
    "TimelineCursor",
    "TimelineWindowRequest",
    "TimelineEntry",
    "TimelineWindowResponse",
    "AcpTranscriptResponse",
    "StreamEvent",
    // task_board.rs policy-canvas read cluster: wire/model split. Summary and
    // ExportResponse own same-named Swift hand models; WorkspaceResponse maps to
    // the hand PolicyCanvasWorkspace (drops "Response"). They reference
    // the generated PolicyGraphMode (PolicyModels, via Kit alias) and the hand
    // PolicyPipelineDocument (Rust PolicyPipelineDocument, TYPE_RENAMES).
    "PolicyCanvasSummary",
    "PolicyCanvasWorkspaceResponse",
    "PolicyCanvasExportResponse",
    // task_board summary.rs audit/project/machine cluster: wire/model split. The
    // thin hand mirrors keep Int counts; these *Wire types own the daemon decode
    // (UInt counts, explicit snake CodingKeys) and reference the adopted
    // TaskBoardStatus/TaskBoardAgentMode bare. Sync summary deferred.
    "TaskBoardAuditSummary",
    "TaskBoardStatusCount",
    "TaskBoardProjectSummary",
    "TaskBoardMachineSummary",
    // task_board types.rs core item cluster: wire/model split, generate-only. The
    // rich hand models keep their renamed shape (TaskBoardExternalRef drops
    // sync_state, workflow is optional app-side); these *Wire types own the faithful
    // daemon decode. The adopted TaskBoardStatus/Priority/AgentMode are referenced
    // bare; ExternalRefProvider/TaskBoardWorkflowStatus take the suffix.
    "TaskBoardItem",
    "TaskBoardLaneOrigin",
    "ExternalRef",
    "ExternalRefSyncState",
    "ExternalRefProvider",
    "PlanningState",
    "TaskBoardWorkflowState",
    "TaskBoardWorkflowStatus",
    "TaskUsage",
    // task_board progress_rollup.rs per-umbrella subtree roll-up, nested as a
    // dictionary in the items-list response below (generate-only, plain counts).
    "TaskBoardProgressRollup",
    // task_board.rs items-list response wrapper (Swift hand TaskBoardListItemsResponse);
    // wraps [TaskBoardItemWire] for the /v1/task-board/items decode reroute.
    "TaskBoardListItemsResponse",
    "TaskBoardItemPositionSnapshot",
    "TaskBoardShiftedItemRevision",
    "TaskBoardItemPositionMutationResponse",
    // task_board planning.rs transition + its protocol response wrapper (the response
    // carries the rerouted TaskBoardItemWire); Swift hands are TaskBoardPlanningTransition
    // /TaskBoardPlanningResponse.
    "PlanningTransition",
    "TaskBoardPlanningResponse",
    // task_board evaluation.rs summary + record + outcome + signal-failure. The record
    // carries the rerouted TaskBoardItemWire and references TaskStatus/TaskBoardStatus
    // /TaskBoardWorkflowStatus bare; hands keep their renamed shape (drop signal_failures).
    "TaskBoardEvaluationSummary",
    "TaskBoardEvaluationRecord",
    "TaskBoardEvaluationOutcome",
    "EvaluationSignalFailure",
    // task_board dispatch.rs + policy.rs graph. The hands are TaskBoard*-prefixed and
    // flatten the internally-tagged enums (DispatchReadiness/BlockReason/SessionIntent
    // /PolicyDecision) into discriminator structs; these *Wire types own the faithful
    // tagged-enum decode and the lifecycle/failures fields are dropped via OMITTED_WIRE_FIELDS.
    "DispatchExecutionSummary",
    "DispatchPlan",
    "DispatchAppliedTask",
    "DispatchReadiness",
    "DispatchBlockReason",
    "SessionIntent",
    "TaskCreationIntent",
    "WorkerIntent",
    "ReviewerIntent",
    "EvaluatorIntent",
    "FollowUpPhase",
    "PlanApprovalBlockReason",
    // PolicyDecision / PolicyReasonCode are NOT listed here: HarnessMonitorPolicyModels
    // already owns those generated wire types, so the dispatch module imports that module
    // and references them bare rather than re-emitting (and clashing across the two modules).
    // task_board machines.rs host machine: Swift hand is TaskBoardHostMachine
    // (renamed); agent_modes references the adopted TaskBoardAgentMode bare.
    "Machine",
    // agents/acp/probe.rs runtime-doctor probe: Swift hands are AcpRuntimeProbeResponse
    // /AcpRuntimeProbe (thin mirrors); the probe references AcpAuthState bare.
    "AcpRuntimeProbeResponse",
    "AcpRuntimeProbe",
    // session/types/agents.rs persona: Swift hands are AgentPersona/PersonaSymbol; the
    // symbol is the internally-tagged sf_symbol/asset enum.
    "AgentPersona",
    "PersonaSymbol",
    // agents/runtime/models/mod.rs catalog: Swift hands are RuntimeModelCatalog
    // /RuntimeModel; tier (RuntimeModelTier) and effort family (EffortKind) reference bare.
    "RuntimeModelCatalog",
    "RuntimeModel",
    // agents/acp/catalog/mod.rs descriptor: Swift hands are AcpAgentDescriptor and
    // AcpDoctorProbe; DoctorProbe takes the suffix (the map renames it to AcpDoctorProbe
    // to avoid clashing with the hand type), model_catalog reuses RuntimeModelCatalogWire.
    "AcpAgentDescriptor",
    "DoctorProbe",
    // protocol/websocket.rs config push: Swift hand is MonitorConfiguration; the wire nests
    // the generated AgentPersonaWire/RuntimeModelCatalogWire/AcpAgentDescriptorWire and the
    // optional AcpRuntimeProbeResponseWire, all in this same module (no import).
    "WsConfigPayload",
    // manager.rs acp inspect response: Swift hand is AcpAgentInspectResponse; its agents field
    // references the renamed AcpAgentInspectSnapshotWire (the snapshot decode struct).
    "AcpAgentInspectResponse",
    // ACP incident + agents-reconciled push payloads (daemon-internal Serialize structs). The
    // reconciled payload nests AcpAgentSnapshotWire + AcpAgentInspectResponseWire.
    "AcpProcessIncidentPayload",
    "AcpBridgeResyncIncidentPayload",
    "AcpAgentsReconciledPayload",
    // reviews local-clone progress push payload: internally-tagged enum the Swift hand flattens.
    "LocalCloneProgressEventPayload",
    // permission_bridge.rs acp permission item: Swift hand is AcpPermissionItem (toolCall and
    // options modelled as raw JSON); referenced by AcpPermissionBatchWire.requests.
    "AcpPermissionItem",
    // permission_bridge.rs acp permission decision: the resolveManagedAcpPermission request
    // body. Internally-tagged enum (decision tag); the hand AcpPermissionDecision relies on
    // convertToSnakeCase for request_ids, the wire pins it.
    "AcpPermissionDecision",
    // protocol/managed_agents.rs umbrella: ManagedAgentSnapshot (adjacently-tagged over the
    // three transport snapshots) + its list response, the managed-agent endpoint return types.
    "ManagedAgentSnapshot",
    "ManagedAgentListResponse",
    // daemon-state /v1/diagnostics cluster: the rich hand DaemonDiagnosticsReport/DaemonManifest
    // /DaemonDiagnostics/LaunchAgentStatus models own these bare names, so the wire suffixes
    // them and the hand init(wire:) maps back (drops acp_runtime_probe + ownership).
    "DaemonDiagnosticsReport",
    "DaemonManifest",
    "HostBridgeManifest",
    "HostBridgeCapabilityManifest",
    "DaemonBinaryStamp",
    "DaemonAuditEvent",
    "DaemonDiagnostics",
    "LaunchAgentStatus",
    // session signal cluster (events.rs SessionSignalRecord + signal/mod.rs Signal tree): rich hand
    // models (Identifiable, computed effectiveStatus, custom SignalPayload decode) own these bare
    // names, so the wire suffixes them; SignalPriority/AckResult/SessionSignalStatus stay bare.
    "SessionSignalRecord",
    "Signal",
    "SignalPayload",
    "DeliveryConfig",
    "SignalAck",
    // agent registration runtime capabilities (agents/runtime/mod.rs): thin hand mirrors relying
    // on convertFromSnakeCase, so the wire suffixes them (AgentRegistrationWire is already named).
    "RuntimeCapabilities",
    "HookIntegrationDescriptor",
    // SessionDetail capstone (summaries.rs): the aggregate the session-mutation endpoints return.
    // SessionDetail suffixes to SessionDetailWire; AgentRegistration suffixes so the agents field
    // references the generated AgentRegistrationWire (the other five members already suffix).
    "SessionDetail",
    "AgentRegistration",
    // session push-event payloads (summaries.rs): the watch-loop stream frames. Each nests
    // already-suffixed member wires (project/session summary, session detail, timeline entry,
    // signal record, observer, agent activity).
    "SessionsUpdatedPayload",
    "SessionsUpdatedDeltaPayload",
    "SessionUpdatedPayload",
    "SessionExtensionsPayload",
    // task_board orchestrator credential responses (runtime_config.rs): thin hand mirrors.
    "TaskBoardGitHubTokensSyncResponse",
    "TaskBoardTodoistTokenSyncResponse",
    "TaskBoardOpenRouterTokenSyncResponse",
    // host-bridge reconfigure response (bridge/types.rs): nests the daemon-state capability wire.
    "BridgeStatusReport",
    // task_board sync summary (summary.rs + external/sync.rs): the syncTaskBoard return + orchestrator
    // run-summary member. ExternalSyncOperation maps to the hand TaskBoardExternalSyncOperation.
    "TaskBoardSyncSummary",
    "TaskBoardProviderSyncSummary",
    "ExternalSyncOperation",
    // GitHubProjectConfig sub-tree (github/config.rs) nested in the orchestrator settings.
    "GitHubProjectConfig",
    "GitHubAutomationLabels",
    "GitHubRequestedReviewers",
    "GitHubAutomationToggles",
    "ProtectedPathRule",
    // task_board orchestrator settings + status tree (orchestrator/types.rs). The settings nest
    // the GitHubProjectConfigWire (via TYPE_RENAMES on the Rust alias) plus the two inbox configs;
    // the status nests the run summary (sync/audit/dispatch/evaluation wires) and tick info. The
    // Workflow/TickPhase/RunStatus enums + TaskBoardStatus/TaskBoardWorkflowStatus ride bare.
    "TaskBoardOrchestratorSettings",
    "TaskBoardGitHubInboxConfig",
    "TaskBoardTodoistInboxConfig",
    "TaskBoardOrchestratorTickInfo",
    "TaskBoardOrchestratorRunSummary",
    "TaskBoardWorkflowExecutionCount",
    "TaskBoardOrchestratorStatus",
    // task_board git runtime config tree (runtime_config.rs) + secret-handoff response
    // (daemon/protocol/task_board.rs). The signing mode is the decoder-agnostic hand open enum
    // TaskBoardGitSigningMode, referenced bare; everything else is a thin wire/model mirror.
    "TaskBoardGitRuntimeConfig",
    "TaskBoardGitRuntimeProfile",
    "TaskBoardGitSigningConfig",
    "TaskBoardGitRepositoryOverride",
    "TaskBoardGitRuntimeSecretHandoffPrepareResponse",
    // task_board git signing verify outcome (daemon/protocol/task_board.rs): an internally-tagged
    // (tag = "outcome") enum with unit + struct variants, emitted as a Swift associated-value enum.
    "TaskBoardGitSigningVerifyResponse",
    // acp_events broadcast push frame (daemon/agent_acp/event_frame.rs) + its conversation event
    // (agents/runtime/event.rs). ConversationEvent.kind rides through as JSONValue (passthrough);
    // managed_agent_family is the bare ManagedAgentKind the map validates is acp.
    "AcpEventBatchPayload",
    "ConversationEvent",
];

/// Rust serde types the generator must NOT emit for a module even though they
/// carry a serde derive: they reference a daemon-only type with no Swift mirror
/// (e.g. `SessionMutationResponse` -> `SessionState`), or the Swift app does not
/// model that endpoint at all. Empty until a module needs an exclusion; with it
/// empty every module stays byte-identical.
const SKIP_TYPES: &[&str] = &[
    // session_requests.rs: the seven types with no Swift hand model.
    // SessionMutationResponse also references the unmirrored Rust `SessionState`.
    "SessionLeaveRequest",
    "SessionTitleRequest",
    "SessionJoinRequest",
    "SignalAckRequest",
    "SessionMutationResponse",
    "AgentRuntimeSessionRegistrationRequest",
    "AgentRuntimeSessionRegistrationResponse",
    // reviews files service.rs/local_clone.rs: daemon-internal serde types behind
    // the FilesLargeDiffStrategy / LocalCloneListEntry facade. StrategyConfig is
    // daemon config; RepoKey/RegistryEntry/LocalCloneRegistry are the on-disk
    // clones registry. None cross the wire to Swift.
    "StrategyConfig",
    "RepoKey",
    "RegistryEntry",
    "LocalCloneRegistry",
    "BlobTextProjection",
    // websocket probe/inspect push payloads still pending: WsRuntimeProbeUpdate wraps the
    // now-generated AcpRuntimeProbeResponse but has no decode reroute yet, and WsAcpInspect
    // references the still-unmigrated AcpAgentInspectResponse. WsConfigPayload itself is now
    // generated (it is the MonitorConfiguration wire - personas/runtime_models/acp_agents
    // /runtime_probe all generated) and emits WsConfigPayloadWire into this module.
    "WsRuntimeProbeUpdate",
    "WsAcpInspect",
    // session tasks enums kept hand-authored: each has a legacy-tolerant custom
    // init(from:) a generated plain enum would regress - TaskStatus accepts legacy
    // camelCase inProgress/inReview/awaitingReview, TaskQueuePolicy accepts legacy
    // reassignWhenFree, ReviewVerdict accepts request-changes/requestChanges. The
    // three plain enums (TaskSeverity/TaskSource/ReviewPointState) carry only a
    // .title and no custom decode, so they are adopted generated (bare, closed) -
    // their .title moves to a Swift extension and the structs reference them bare.
    "TaskStatus",
    "TaskQueuePolicy",
    "ReviewVerdict",
    // ReviewPoint (struct) is referenced bare by the already-generated
    // SessionRequestsWireTypes (TaskSubmitReviewRequestWire.points) whose +Wire
    // mapping passes model.points straight through; suffixing it would ripple that
    // file + break the pass-through. Keep it bare-hand (Review/ReviewConsensus wire
    // structs reference the hand ReviewPoint) until session_requests also adopts it.
    "ReviewPoint",
    // policy_graph/store.rs serde types OUTSIDE the simulate/audit cluster: the
    // save/promote/make-live responses already decode via the plain policy-wire
    // decoder and GraphPolicyGate is daemon-internal. Adding store.rs as a
    // policy-module source for the cluster wire types must not also emit these
    // (bare names that would clash / produce dead types). The make-live request
    // and response are hand-authored in HarnessMonitorPolicyPipelineModels
    // because the app response also carries the post-promotion workspace snapshot
    // the store.rs type does not model, and types `document` as the hand
    // PolicyPipelineDocument rather than the bare generated PolicyGraph.
    "GraphPolicyGate",
    "PolicyPipelineSaveResponse",
    "PolicyPipelinePromoteRequest",
    "PolicyPipelinePromoteResponse",
    "PolicyPipelineMakeLiveRequest",
    "PolicyPipelineMakeLiveResponse",
];

/// Whether a Rust type is on the generator's skip list (see `SKIP_TYPES`).
fn is_skipped_type(rust_name: &str) -> bool {
    SKIP_TYPES.contains(&rust_name)
}

/// Rust type names whose Swift hand model is named differently, mapped to that
/// Swift name. Applied to references so a generated wire type that references a
/// hand type (defined in another module) points at its real Swift name rather
/// than the Rust name. Distinct from the `Wire` suffix, which is for types this
/// generator also emits.
const TYPE_RENAMES: &[(&str, &str)] = &[
    // task_board sync summary: the Rust external-sync enums are the Swift hand TaskBoard-prefixed
    // ones (decoder-agnostic, referenced bare by the sync-summary wire structs).
    ("ExternalProvider", "TaskBoardExternalProvider"),
    ("ExternalSyncAction", "TaskBoardExternalSyncAction"),
    // GitHubProjectConfig.enabled_automations: the Rust GitHubAutomation is the Swift closed
    // snake_case enum TaskBoardGitHubAutomation (decoder-agnostic, referenced bare).
    ("GitHubAutomation", "TaskBoardGitHubAutomation"),
    // reviews ReviewFile.language_hint: Rust HarnessCodeLanguage is the Swift
    // hand enum HarnessReviewFileLanguage.
    ("HarnessCodeLanguage", "HarnessReviewFileLanguage"),
    // reviews types.rs request methods: Rust GitHubMergeMethod (task_board) is
    // the Swift hand enum TaskBoardGitHubMergeMethod.
    ("GitHubMergeMethod", "TaskBoardGitHubMergeMethod"),
    // orchestrator settings.github_project: the Rust field uses the type alias
    // TaskBoardGitHubProjectConfig (= github::GitHubProjectConfig), so repoint it at the
    // already-generated GitHubProjectConfigWire instead of re-emitting the sub-tree.
    ("TaskBoardGitHubProjectConfig", "GitHubProjectConfigWire"),
    // task_board.rs policy-canvas read cluster: Rust PolicyPipelineDocument is a
    // type alias for PolicyGraph (policy_graph.rs:389). The Swift app re-models it
    // as the hand PolicyPipelineDocument (Kit, explicit snake CodingKeys,
    // plain-decoder-safe), so the canvas wire fields point at that hand name. The
    // token only appears in task_board.rs fields, never the generated PolicyGraph.
    ("PolicyPipelineDocument", "PolicyPipelineDocument"),
    // task_board types.rs: the Rust AgentMode enum is adopted under the Swift hand
    // name TaskBoardAgentMode (the app owns the bare name), so the generated open
    // enum replaces the hand one in place. No generated module references AgentMode
    // as a field type yet, so the rename is scoped to the enums module.
    ("AgentMode", "TaskBoardAgentMode"),
    // acp catalog/tags.rs: CapabilityTag is `type CapabilityTag = String`, so the
    // descriptor's `capabilities: Vec<CapabilityTag>` field is `[String]` (the app
    // hand already types it as [String]). The token only appears in that field.
    ("CapabilityTag", "String"),
    // acp inspect: the rich AcpAgentInspectSnapshot has no serde derive; its owned decode
    // struct AcpAgentInspectSnapshotDecode is emitted AS AcpAgentInspectSnapshotWire (the
    // definition rename), and the response's `Vec<AcpAgentInspectSnapshot>` field reference
    // points at that same Wire name. Both tokens only appear in the acp-inspect module.
    (
        "AcpAgentInspectSnapshotDecode",
        "AcpAgentInspectSnapshotWire",
    ),
    ("AcpAgentInspectSnapshot", "AcpAgentInspectSnapshotWire"),
    // acp permission: the no-derive AcpPermissionBatch's owned decode struct emits as
    // AcpPermissionBatchWire, and the external-crate PermissionOption (the app models
    // permission options as raw JSON) maps to JSONValue. Both tokens are acp-permission only.
    ("AcpPermissionBatchDecode", "AcpPermissionBatchWire"),
    ("PermissionOption", "JSONValue"),
    ("AcpPermissionOption", "JSONValue"),
    // acp snapshot: AcpAgentSnapshotDecode emits as AcpAgentSnapshotWire, and its
    // pending_permission_batches: Vec<AcpPermissionBatch> field reference resolves to the
    // generated AcpPermissionBatchWire (the public AcpPermissionBatch has no derive).
    ("AcpAgentSnapshotDecode", "AcpAgentSnapshotWire"),
    ("AcpPermissionBatch", "AcpPermissionBatchWire"),
    // managed-agents umbrella: the public no-derive AcpAgentSnapshot referenced by the
    // ManagedAgentSnapshot Acp variant resolves to the generated AcpAgentSnapshotWire.
    ("AcpAgentSnapshot", "AcpAgentSnapshotWire"),
    // acp start request: the public no-derive AcpAgentStartRequest's owned decode struct emits
    // as AcpAgentStartRequestWire (the request body for startManagedAcpAgent).
    ("AcpAgentStartRequestDecode", "AcpAgentStartRequestWire"),
    // agent-tui input request: the public AgentTuiInputRequest uses #[serde(try_from)], so its
    // private RawAgentTuiInputRequest proxy emits as AgentTuiInputRequestWire.
    ("RawAgentTuiInputRequest", "AgentTuiInputRequestWire"),
];

/// The Swift name for a Rust wire type: a hand rename when one applies, else the
/// bare name, or `{name}Wire` when the app owns the bare name for a rich model.
/// Applied to both type definitions and every reference so a `Vec<T>` field
/// tracks the suffixed element name.
fn swift_type_name(rust_name: &str, suffixed: &[&str]) -> String {
    if let Some((_, swift_name)) = TYPE_RENAMES.iter().find(|(rust, _)| *rust == rust_name) {
        return (*swift_name).to_string();
    }
    if suffixed.contains(&rust_name) {
        format!("{rust_name}Wire")
    } else {
        rust_name.to_string()
    }
}

/// Map a Rust scalar to its smallest faithful Swift type; pass named types
/// (other generated wire types) through, suffixing wire/model-split names.
#[allow(
    clippy::match_same_arms,
    reason = "separate arms document distinct Rust types with the same Swift wire shape"
)]
fn map_scalar(ident: &str) -> String {
    match ident {
        "u8" => "UInt8",
        "u16" => "UInt16",
        "u32" => "UInt32",
        "u64" => "UInt64",
        "usize" => "UInt",
        "i8" => "Int8",
        "i16" => "Int16",
        "i32" => "Int32",
        "i64" => "Int64",
        "isize" => "Int",
        "f32" => "Float",
        "f64" => "Double",
        "bool" => "Bool",
        "String" | "str" => "String",
        // std::path::PathBuf / Path serialize transparently as a string, and the app mirrors a
        // path field as String (e.g. GitHubProjectConfig.checkout_path).
        "PathBuf" | "Path" => "String",
        // chrono `DateTime<Tz>` serializes as an RFC3339 string and the app
        // mirrors it as String; the timezone type argument does not change the
        // wire shape, so the bare `DateTime` ident is enough to map it.
        "DateTime" => "String",
        // serde_json::Value maps to the app's open JSON value type, which
        // round-trips an arbitrary payload exactly like serde_json::Value.
        // `JsonValue` is the common `use serde_json::Value as JsonValue` alias.
        "Value" | "JsonValue" => "JSONValue",
        other => return swift_type_name(other, WIRE_SUFFIXED_TYPES),
    }
    .to_string()
}

/// The first concrete type argument of an angle-bracketed path segment.
fn first_generic_arg(arguments: &PathArguments) -> Option<&Type> {
    let PathArguments::AngleBracketed(bracketed) = arguments else {
        return None;
    };
    bracketed.args.iter().find_map(|arg| match arg {
        GenericArgument::Type(ty) => Some(ty),
        _ => None,
    })
}

/// The empty literal for a Swift collection type: `[:]` for a top-level
/// dictionary (`[Key: Value]`, where the key carries no nested bracket) and `[]`
/// for an array. Keeps a `#[serde(default)]` dictionary field from defaulting to
/// the empty-array literal, which would not type-check.
fn empty_collection_literal(swift_type: &str) -> &'static str {
    let is_dictionary = swift_type
        .strip_prefix('[')
        .and_then(|rest| rest.split_once(": "))
        .is_some_and(|(key, _)| !key.contains('['));
    if is_dictionary { "[:]" } else { "[]" }
}

/// The Swift zero value for a scalar or array type, used to default the
/// required fields of `Default`-deriving structs.
fn zero_value(swift_type: &str) -> Option<String> {
    if swift_type.starts_with('[') {
        return Some(empty_collection_literal(swift_type).to_string());
    }
    let value = match swift_type {
        "Bool" => "false",
        "String" => "\"\"",
        "Float" | "Double" | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt" | "UInt8"
        | "UInt16" | "UInt32" | "UInt64" => "0",
        // An open JSON value defaults to its null case, matching serde's
        // `#[serde(default)]` on a `serde_json::Value` (which is `Value::Null`).
        "JSONValue" => "JSONValue.null",
        _ => return None,
    };
    Some(value.to_string())
}

// ---------------------------------------------------------------------------
// Source parsing: Rust AST -> Swift descriptors.
// ---------------------------------------------------------------------------

/// Each zero-argument `defaults::*` function mapped to the Swift literal it
/// returns, keyed by function name.
type DefaultLiterals = HashMap<String, String>;

/// Cross-type facts needed to fill bare `#[serde(default)]` fields: each enum's
/// `#[default]` variant (as a Swift case), the structs that derive `Default`
/// (so a zero-argument initializer exists to call), and every literal `const`
/// (as a Swift literal) so a `#[serde(default = "fn")]` whose body returns a
/// named constant resolves to that constant's value.
struct SymbolTable {
    enum_default_variant: HashMap<String, String>,
    structs_with_default: HashSet<String>,
    const_literals: HashMap<String, String>,
    /// Every named-field struct keyed by name, so a `#[serde(flatten)]` field
    /// can splice the flattened struct's fields into its parent inline.
    struct_fields: HashMap<String, FieldsNamed>,
}

/// The serde container config read from a type's attributes.
struct SerdeContainer {
    tag: Option<String>,
    content: Option<String>,
    rename_all: Option<String>,
}

/// The serde field config read from a field's attributes.
struct SerdeField {
    rename: Option<String>,
    default_fn: Option<String>,
    has_default: bool,
    flatten: bool,
    skip_serializing_if: Option<String>,
}

struct SerdeVariant {
    rename: Option<String>,
    aliases: Vec<String>,
}

/// The identifiers inside every `#[derive(...)]` on an item.
fn derive_idents(attrs: &[Attribute]) -> Vec<String> {
    let mut idents = Vec::new();
    for attr in attrs {
        if !attr.path().is_ident("derive") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            if let Some(ident) = meta.path.get_ident() {
                idents.push(ident.to_string());
            }
            Ok(())
        });
    }
    idents
}

/// Whether an item participates in the serde wire format.
fn has_serde(attrs: &[Attribute]) -> bool {
    derive_idents(attrs)
        .iter()
        .any(|derive| derive == "Serialize" || derive == "Deserialize")
}

/// Whether an item derives `Default`.
fn derives_default(attrs: &[Attribute]) -> bool {
    derive_idents(attrs)
        .iter()
        .any(|derive| derive == "Default")
}

/// Whether a variant carries the `#[default]` attribute.
fn has_default_attr(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|attr| attr.path().is_ident("default"))
}

/// Read `#[serde(tag = "...", content = "...", rename_all = "...")]` from a
/// type's attributes.
fn serde_container(attrs: &[Attribute]) -> SerdeContainer {
    let mut tag = None;
    let mut content = None;
    let mut rename_all = None;
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            let is_tag = meta.path.is_ident("tag");
            let is_content = meta.path.is_ident("content");
            let is_rename_all = meta.path.is_ident("rename_all");
            if let Ok(value) = meta.value() {
                let lit: Lit = value.parse()?;
                if let Lit::Str(text) = lit {
                    if is_tag {
                        tag = Some(text.value());
                    } else if is_content {
                        content = Some(text.value());
                    } else if is_rename_all {
                        rename_all = Some(text.value());
                    }
                }
            }
            Ok(())
        });
    }
    SerdeContainer {
        tag,
        content,
        rename_all,
    }
}

/// Read `#[serde(rename = ..., default[ = "..."])]` from a field's attributes.
fn serde_field(attrs: &[Attribute]) -> SerdeField {
    let mut rename = None;
    let mut default_fn = None;
    let mut has_default = false;
    let mut flatten = false;
    let mut skip_serializing_if = None;
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            let is_default = meta.path.is_ident("default");
            let is_rename = meta.path.is_ident("rename");
            let is_skip = meta.path.is_ident("skip_serializing_if");
            if is_default {
                has_default = true;
            }
            if meta.path.is_ident("flatten") {
                flatten = true;
            }
            if let Ok(value) = meta.value() {
                let lit: Lit = value.parse()?;
                if let Lit::Str(text) = lit {
                    if is_default {
                        default_fn = Some(text.value());
                    } else if is_rename {
                        rename = Some(text.value());
                    } else if is_skip {
                        skip_serializing_if = Some(text.value());
                    }
                }
            }
            Ok(())
        });
    }
    SerdeField {
        rename,
        default_fn,
        has_default,
        flatten,
        skip_serializing_if,
    }
}

/// Read the canonical wire name and decode-only aliases from an enum variant.
fn serde_variant(attrs: &[Attribute]) -> SerdeVariant {
    let mut rename = None;
    let mut aliases = Vec::new();
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            let is_rename = meta.path.is_ident("rename");
            let is_alias = meta.path.is_ident("alias");
            if let Ok(value) = meta.value() {
                let lit: Lit = value.parse()?;
                if let Lit::Str(text) = lit {
                    if is_rename {
                        rename = Some(text.value());
                    } else if is_alias {
                        aliases.push(text.value());
                    }
                }
            }
            Ok(())
        });
    }
    SerdeVariant { rename, aliases }
}

/// Parse the defaults sources, mapping each zero-argument default function to the
/// Swift literal it returns. The `is_default_*` predicate helpers take a parameter
/// and are skipped. A module may name several defaults files when its default fns
/// are split across modules (e.g. files-core resolves `preview_line_limit` from
/// files/preview.rs alongside its mod.rs defaults).
fn parse_defaults(sources: &[&str], symbols: &SymbolTable) -> DefaultLiterals {
    let mut literals = DefaultLiterals::new();
    for source in sources {
        let file = syn::parse_file(source).expect("defaults.rs parses");
        for item in file.items {
            let Item::Fn(function) = item else {
                continue;
            };
            if !function.sig.inputs.is_empty() {
                continue;
            }
            if let Some(literal) = block_literal(&function.block, symbols) {
                literals.insert(function.sig.ident.to_string(), literal);
            }
        }
    }
    literals
}

/// The Swift literal returned by a single-expression function body.
fn block_literal(block: &syn::Block, symbols: &SymbolTable) -> Option<String> {
    let [Stmt::Expr(expr, _)] = block.stmts.as_slice() else {
        return None;
    };
    expr_literal(expr, symbols)
}

/// Render a default-fn body expression as a Swift literal: a Rust literal
/// (including `"...".to_string()`), an enum-variant path (`SessionRole::Worker`
/// -> `.worker`), or a named constant (`DEFAULT_ROWS` -> its collected literal).
fn expr_literal(expr: &Expr, symbols: &SymbolTable) -> Option<String> {
    match expr {
        Expr::Lit(literal) => lit_to_swift(&literal.lit),
        Expr::MethodCall(call)
            if (call.method == "to_string" || call.method == "to_owned")
                && call.args.is_empty() =>
        {
            expr_literal(&call.receiver, symbols)
        }
        Expr::Path(path) => {
            let segments = &path.path.segments;
            let last = segments.last()?.ident.to_string();
            if segments.len() >= 2 {
                // `Type::Variant` -> the Swift enum case `.variant`.
                Some(format!(".{}", escape_keyword(pascal_to_camel(&last))))
            } else {
                // A bare identifier names a constant collected by the symbol table.
                symbols.const_literals.get(&last).cloned()
            }
        }
        _ => None,
    }
}

/// Render a Rust literal as the equivalent Swift literal.
fn lit_to_swift(lit: &Lit) -> Option<String> {
    match lit {
        Lit::Bool(value) => Some(if value.value { "true" } else { "false" }.to_string()),
        Lit::Str(value) => Some(format!("\"{}\"", value.value())),
        Lit::Int(value) => Some(value.base10_digits().to_string()),
        Lit::Float(value) => Some(value.base10_digits().to_string()),
        _ => None,
    }
}

/// Walk every source once to collect cross-type defaulting facts.
fn build_symbol_table(sources: &[&str]) -> SymbolTable {
    let mut enum_default_variant = HashMap::new();
    let mut structs_with_default = HashSet::new();
    let mut const_literals = HashMap::new();
    let mut struct_fields = HashMap::new();
    for source in sources {
        let file = syn::parse_file(source).expect("policy source parses");
        for item in file.items {
            match item {
                Item::Struct(item) => {
                    if derives_default(&item.attrs) {
                        structs_with_default.insert(item.ident.to_string());
                    }
                    if let Fields::Named(fields) = &item.fields {
                        struct_fields.insert(item.ident.to_string(), fields.clone());
                    }
                }
                Item::Enum(item) => {
                    if let Some(variant) = item
                        .variants
                        .iter()
                        .find(|variant| has_default_attr(&variant.attrs))
                    {
                        enum_default_variant.insert(
                            item.ident.to_string(),
                            escape_keyword(pascal_to_camel(&variant.ident.to_string())),
                        );
                    }
                }
                Item::Const(item) => {
                    // Literal constants only (`const ROWS: u16 = 30;`); a const
                    // whose value is itself an expression is out of scope.
                    if let Expr::Lit(literal) = item.expr.as_ref()
                        && let Some(swift) = lit_to_swift(&literal.lit)
                    {
                        const_literals.insert(item.ident.to_string(), swift);
                    }
                }
                _ => {}
            }
        }
    }
    SymbolTable {
        enum_default_variant,
        structs_with_default,
        const_literals,
        struct_fields,
    }
}

/// Build Swift field descriptors from named Rust fields.
/// `(Rust struct name, Rust field name)` pairs whose value-typed field the app
/// models as OPTIONAL rather than a defaulted value. These fields carry
/// `skip_serializing_if = "*::is_default"`, so the daemon omits them when they
/// equal their `Default`, and the hand model distinguishes that absence (`nil`)
/// from a present non-default value. The generated wire field then decodes with a
/// bare `decodeIfPresent` (no `?? Default()` coalesce) so absence maps to `nil`,
/// matching the hand model the wire/model split maps into. Keyed by the Rust
/// names so the lookup runs before the `Wire` suffix is applied. Guarded in
/// `build_fields`: a listed field must actually carry a `*::is_default` skip
/// predicate, so the list can never silently drop a value the daemon still sends.
const SKIP_DEFAULT_OPTIONAL_FIELDS: &[(&str, &str)] = &[("TaskBoardItem", "workflow")];

/// Whether `(struct_name, field_name)` is in `SKIP_DEFAULT_OPTIONAL_FIELDS`.
fn is_skip_default_optional(struct_name: &str, field_name: &str) -> bool {
    SKIP_DEFAULT_OPTIONAL_FIELDS
        .iter()
        .any(|(owner, field)| *owner == struct_name && *field == field_name)
}

/// Bare `#[serde(default)]` value fields whose Rust type has a manual, nonzero
/// `Default` implementation and whose immediate Swift hand model already owns
/// that canonical default. The generated wire keeps these values optional so a
/// legacy payload's absence reaches the hand model as `nil`, without copying
/// the nested default literals into codegen. Entries are assertion-guarded in
/// `build_fields`: they must remain non-optional bare-default fields for which
/// codegen cannot otherwise resolve a decoder fallback.
const HAND_MODEL_DEFAULT_OPTIONAL_FIELDS: &[(&str, &str)] = &[
    ("TaskBoardOrchestratorSettings", "scheduling"),
    ("TaskBoardOrchestratorSettings", "retry"),
    ("TaskBoardOrchestratorSettings", "reviewers"),
];

/// Whether `(struct_name, field_name)` is in `HAND_MODEL_DEFAULT_OPTIONAL_FIELDS`.
fn is_hand_model_default_optional(struct_name: &str, field_name: &str) -> bool {
    HAND_MODEL_DEFAULT_OPTIONAL_FIELDS
        .iter()
        .any(|(owner, field)| *owner == struct_name && *field == field_name)
}

/// `(Rust struct name, Rust field name)` pairs dropped from the generated wire
/// type because the app does not reuse them (the hand model omits them). Decode
/// stays faithful: `JSONDecoder` ignores keys with no matching property, so an
/// omitted field just leaves the daemon's extra key unread. Keyed by the Rust
/// names so the lookup runs before the `Wire` suffix. Use this to keep a wire type
/// minimal instead of pulling a whole sub-graph the app never reads (e.g. the
/// dispatch lifecycle and its step/phase/status enums).
const OMITTED_WIRE_FIELDS: &[(&str, &str)] = &[
    ("DispatchExecutionSummary", "failures"),
    ("DispatchPlan", "lifecycle"),
    ("DispatchAppliedTask", "lifecycle"),
    ("DispatchAppliedTask", "read_only_workflow"),
    ("DispatchAppliedTask", "write_workflow"),
    // acp process incident: the daemon-only remediation booleans the Swift hand never models.
    ("AcpProcessIncidentPayload", "restart_applied"),
    ("AcpProcessIncidentPayload", "backoff_applied"),
    ("AcpProcessIncidentPayload", "quarantine_applied"),
    // acp descriptor daemon-only injection config: the app does not model how the
    // daemon maps model/effort onto ACP startup, so these (and their tagged
    // AcpSpawnConfiguration / transport sub-enums) never cross to Swift.
    ("AcpAgentDescriptor", "spawn_configuration"),
    ("AcpAgentDescriptor", "session_configuration"),
    // acp inspect snapshot: the hand AcpAgentInspectSnapshot has no transport-family field,
    // so dropping managed_agent_family (ManagedAgentKind) keeps the wire all-primitive.
    ("AcpAgentInspectSnapshotDecode", "managed_agent_family"),
    // acp permission batch: the hand AcpPermissionBatch has no transport-family field.
    ("AcpPermissionBatchDecode", "managed_agent_family"),
    // acp snapshot: the hand AcpAgentSnapshot drops the transport family, process_key,
    // permission_mode and permission_log_path (daemon-internal); the app does not model them.
    ("AcpAgentSnapshotDecode", "managed_agent_family"),
    ("AcpAgentSnapshotDecode", "process_key"),
    ("AcpAgentSnapshotDecode", "permission_mode"),
    ("AcpAgentSnapshotDecode", "permission_log_path"),
    // daemon diagnostics: the hand DaemonDiagnosticsReport has no acp_runtime_probe field, and the
    // hand DaemonManifest drops ownership (daemon-internal entry-point discriminator). Dropping
    // both keeps the wire to the shape the app actually decodes - matching today's convert decode,
    // which simply ignores the unmodeled keys.
    ("DaemonDiagnosticsReport", "acp_runtime_probe"),
    ("DaemonManifest", "ownership"),
    // sync operation: the hand TaskBoardExternalSyncOperation drops the changed/unsupported field
    // lists (Vec<ExternalSyncField>, a daemon-only enum with no Swift mirror).
    ("ExternalSyncOperation", "changed_fields"),
    ("ExternalSyncOperation", "unsupported_fields"),
    // Remote-routing configuration is not consumed by the initial automation
    // inspector mapping. JSONDecoder safely ignores these response keys while
    // the automation status, workflow kind, and scheduler settings ship.
    ("TaskBoardOrchestratorSettings", "repositories"),
    ("TaskBoardOrchestratorSettings", "execution_hosts"),
    ("TaskBoardOrchestratorSettings", "local_execution_host"),
    ("TaskBoardOrchestratorSettings", "admission_policy"),
    (
        "TaskBoardOrchestratorSettingsUpdateRequest",
        "local_execution_host",
    ),
];

/// Whether `(struct_name, field_name)` is in `OMITTED_WIRE_FIELDS`.
fn is_omitted_field(struct_name: &str, field_name: &str) -> bool {
    OMITTED_WIRE_FIELDS
        .iter()
        .any(|(owner, field)| *owner == struct_name && *field == field_name)
}

/// Rust struct fields whose value carries a hand-rolled (non-derive) serde shape the
/// generator cannot mirror as a typed Swift property - emit them as a raw `JSONValue`
/// passthrough so the wire round-trips the payload exactly and the hand `init(wire:)` map
/// re-decodes the typed value. Used for `AcpAgentSnapshotDecode.status` (the Rust AgentStatus
/// has a custom hybrid bare-string-or-tagged-object Serialize/Deserialize, and the Swift app
/// recovers both the flattened status and the disconnect reason/stderr_tail from the payload).
const JSON_PASSTHROUGH_FIELDS: &[(&str, &str)] = &[
    ("AcpAgentSnapshotDecode", "status"),
    // AgentRegistrationWire.runtime is the untagged RuntimeKind (bare string or {kind,id} object).
    // The hand AgentRegistration init collapses it to a String, so the wire passes the payload
    // through as JSONValue and the map re-reads it.
    ("AgentRegistrationWire", "runtime"),
    // ConversationEvent.kind is the richly-tagged ConversationEventKind; the Swift hand
    // AcpConversationEvent keeps it opaque as JSONValue, so the wire passes the payload through.
    ("ConversationEvent", "kind"),
];

/// Whether `(struct_name, field_name)` is in `JSON_PASSTHROUGH_FIELDS`.
fn is_json_passthrough_field(struct_name: &str, field_name: &str) -> bool {
    JSON_PASSTHROUGH_FIELDS
        .iter()
        .any(|(owner, field)| *owner == struct_name && *field == field_name)
}

fn build_fields(
    struct_name: &str,
    fields: &FieldsNamed,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
    derives_default: bool,
) -> Vec<SwiftField> {
    let mut out = Vec::new();
    for field in &fields.named {
        let name = field.ident.as_ref().expect("named field").to_string();
        if is_omitted_field(struct_name, &name) {
            continue;
        }
        let serde = serde_field(&field.attrs);
        if serde.flatten {
            // `#[serde(flatten)]` merges the referenced struct's fields into the
            // parent JSON object; Swift Codable has no flatten, so inline the
            // flattened struct's fields directly into the parent type.
            if let Some(ident) = type_ident(&field.ty)
                && let Some(inner) = symbols.struct_fields.get(&ident)
            {
                out.extend(build_fields(
                    &ident,
                    inner,
                    defaults,
                    symbols,
                    derives_default,
                ));
            }
            continue;
        }
        let coding_key = serde.rename.clone().unwrap_or_else(|| name.clone());
        let swift_type = if is_json_passthrough_field(struct_name, &name) {
            SwiftType {
                name: "JSONValue".to_string(),
                optional: false,
            }
        } else {
            rust_type_to_swift(&field.ty)
        };
        let rust_ident = type_ident(&field.ty);
        let natural_decode_default = field_decode_default(
            &swift_type,
            rust_ident.as_deref(),
            &serde,
            defaults,
            symbols,
        );
        // App-optional value fields drop any `?? Default()` coalesce so an omitted
        // value decodes to nil. Each allow-list has source-shape guards that keep
        // the exception narrow and force maintenance when the Rust contract or
        // codegen's default resolution changes.
        let skip_default_optional = is_skip_default_optional(struct_name, &name);
        assert!(
            !skip_default_optional
                || serde
                    .skip_serializing_if
                    .as_deref()
                    .is_some_and(|predicate| predicate.ends_with("::is_default")),
            "SKIP_DEFAULT_OPTIONAL_FIELDS entry `{struct_name}.{name}` lacks a \
             `*::is_default` skip predicate; it cannot drop a defaulted value"
        );
        let hand_model_default_optional = is_hand_model_default_optional(struct_name, &name);
        assert!(
            !hand_model_default_optional
                || (!swift_type.optional
                    && serde.has_default
                    && serde.default_fn.is_none()
                    && serde.skip_serializing_if.is_none()
                    && natural_decode_default.is_none()),
            "HAND_MODEL_DEFAULT_OPTIONAL_FIELDS entry `{struct_name}.{name}` must remain a \
             non-optional bare `#[serde(default)]` field with no codegen-resolved fallback"
        );
        let force_optional = skip_default_optional || hand_model_default_optional;
        let optional = swift_type.optional || force_optional;
        let decode_default = if force_optional {
            None
        } else {
            natural_decode_default
        };
        let init_default = field_init_default(
            optional,
            decode_default.as_deref(),
            &swift_type.name,
            rust_ident.as_deref(),
            derives_default,
            symbols,
        );
        out.push(SwiftField {
            property: escape_keyword(snake_to_camel(&name)),
            coding_key,
            type_name: swift_type.name,
            optional,
            decode_default,
            init_default,
        });
    }
    out
}

/// The decoder fallback (`?? value`) for a field, or `None` when a synthesized
/// optional decode or a plain required decode is correct.
fn field_decode_default(
    swift_type: &SwiftType,
    rust_ident: Option<&str>,
    serde: &SerdeField,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> Option<String> {
    if !serde.has_default || swift_type.optional {
        return None;
    }
    if swift_type.name.starts_with('[') {
        return Some(empty_collection_literal(&swift_type.name).to_string());
    }
    if let Some(function) = &serde.default_fn {
        let key = function.rsplit("::").next().unwrap_or(function);
        return Some(
            defaults
                .get(key)
                .cloned()
                .unwrap_or_else(|| panic!("no default literal for `{function}`")),
        );
    }
    // The symbol-table maps are keyed by the Rust type name, but a wire/model
    // split gives the field a `Wire`-suffixed Swift type; probe with the Rust
    // ident so a `#[serde(default)]` enum/struct field still resolves its default.
    if let Some(ident) = rust_ident {
        if let Some(variant) = symbols.enum_default_variant.get(ident) {
            return Some(format!(".{variant}"));
        }
        if symbols.structs_with_default.contains(ident) {
            return Some(format!("{}()", swift_type.name));
        }
    }
    zero_value(&swift_type.name)
}

/// Build a Swift struct descriptor from a Rust struct, or `None` for tuple and
/// unit structs (which the policy wire surface does not use).
fn build_struct(
    item: &ItemStruct,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> Option<SwiftStruct> {
    let Fields::Named(fields) = &item.fields else {
        return None;
    };
    let derives = derives_default(&item.attrs);
    let struct_name = item.ident.to_string();
    Some(SwiftStruct {
        name: swift_type_name(&struct_name, WIRE_SUFFIXED_TYPES),
        fields: build_fields(&struct_name, fields, defaults, symbols, derives),
    })
}

/// Whether a struct is a serde-transparent `String` newtype - a single-field
/// tuple struct wrapping `String`, the shape the policy id wrappers use. These
/// emit as Swift `RawRepresentable` wrappers rather than Codable structs.
fn is_string_newtype(item: &ItemStruct) -> bool {
    let Fields::Unnamed(fields) = &item.fields else {
        return false;
    };
    let mut iter = fields.unnamed.iter();
    let (Some(field), None) = (iter.next(), iter.next()) else {
        return false;
    };
    rust_type_to_swift(&field.ty).name == "String"
}

/// Build a `String`-backed enum descriptor from a fieldless Rust enum.
fn build_string_enum(item: &ItemEnum) -> SwiftStringEnum {
    let rename_all = serde_container(&item.attrs).rename_all;
    let cases = item
        .variants
        .iter()
        .map(|variant| {
            assert!(
                matches!(variant.fields, Fields::Unit),
                "untagged enum `{}` has non-unit variant `{}`; externally-tagged enums are out of pilot scope",
                item.ident,
                variant.ident
            );
            let name = variant.ident.to_string();
            let serde = serde_variant(&variant.attrs);
            SwiftStringEnumCase {
                name: escape_keyword(pascal_to_camel(&name)),
                raw_value: serde
                    .rename
                    .unwrap_or_else(|| variant_wire_value(&name, rename_all.as_deref())),
                aliases: serde.aliases,
            }
        })
        .collect();
    SwiftStringEnum {
        name: swift_type_name(&item.ident.to_string(), WIRE_SUFFIXED_TYPES),
        cases,
    }
}

/// Build a tagged enum descriptor from a `#[serde(tag = ...)]` (internally
/// tagged) or `#[serde(tag = ..., content = ...)]` (adjacently tagged) enum.
fn build_tagged_enum(
    item: &ItemEnum,
    tag: &str,
    content: Option<&str>,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> SwiftTaggedEnum {
    let rename_all = serde_container(&item.attrs).rename_all;
    let variants = item
        .variants
        .iter()
        .map(|variant| build_tagged_variant(variant, rename_all.as_deref(), defaults, symbols))
        .collect();
    SwiftTaggedEnum {
        name: swift_type_name(&item.ident.to_string(), WIRE_SUFFIXED_TYPES),
        tag: tag.to_string(),
        content: content.map(str::to_string),
        variants,
    }
}

/// Build one tagged-enum variant descriptor, inlining the payload shape.
fn build_tagged_variant(
    variant: &Variant,
    rename_all: Option<&str>,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> SwiftTaggedVariant {
    let name = variant.ident.to_string();
    let payload = match &variant.fields {
        Fields::Unit => VariantPayload::Unit,
        Fields::Named(fields) => {
            VariantPayload::Fields(build_fields(&name, fields, defaults, symbols, false))
        }
        Fields::Unnamed(fields) => {
            let mut iter = fields.unnamed.iter();
            let (Some(field), None) = (iter.next(), iter.next()) else {
                panic!("variant `{name}` has a multi-field tuple payload; out of pilot scope");
            };
            VariantPayload::Newtype(rust_type_to_swift(&field.ty).name)
        }
    };
    SwiftTaggedVariant {
        case_name: escape_keyword(pascal_to_camel(&name)),
        raw_tag: variant_wire_value(&name, rename_all),
        payload,
    }
}

/// Parse one source file and emit Swift for every serde wire type it declares.
/// Whether a type should be emitted given a module's allow-list. An empty
/// `emit_only` means "emit every non-skipped serde type" (the default for most
/// modules); a non-empty list restricts emission to exactly those Rust type
/// names, so a big mixed source file (e.g. summaries.rs, 51 types) can surface a
/// clean self-contained subset without skip-listing the other forty-odd.
fn is_allowed_type(rust_name: &str, emit_only: &[&str]) -> bool {
    emit_only.is_empty() || emit_only.contains(&rust_name)
}

fn emit_source_decls(
    out: &mut String,
    source: &str,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
    emit_only: &[&str],
) {
    let file = syn::parse_file(source).expect("policy source parses");
    for item in file.items {
        match item {
            Item::Struct(item)
                if has_serde(&item.attrs)
                    && !is_skipped_type(&item.ident.to_string())
                    && is_allowed_type(&item.ident.to_string(), emit_only) =>
            {
                if let Some(spec) = build_struct(&item, defaults, symbols) {
                    out.push('\n');
                    emit_struct(out, &spec);
                } else if is_string_newtype(&item) {
                    out.push('\n');
                    emit_newtype(
                        out,
                        &swift_type_name(&item.ident.to_string(), WIRE_SUFFIXED_TYPES),
                    );
                }
            }
            Item::Enum(item)
                if has_serde(&item.attrs)
                    && !is_skipped_type(&item.ident.to_string())
                    && is_allowed_type(&item.ident.to_string(), emit_only) =>
            {
                out.push('\n');
                emit_enum_item(out, &item, defaults, symbols);
            }
            _ => {}
        }
    }
}

/// Emit a Swift enum, dispatching on whether the Rust enum is internally tagged.
fn emit_enum_item(
    out: &mut String,
    item: &ItemEnum,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) {
    let container = serde_container(&item.attrs);
    if let Some(tag) = container.tag {
        emit_tagged_enum(
            out,
            &build_tagged_enum(item, &tag, container.content.as_deref(), defaults, symbols),
        );
    } else {
        let spec = build_string_enum(item);
        if OPEN_STRING_ENUMS.contains(&spec.name.as_str()) {
            emit_open_enum(out, &spec);
        } else {
            emit_string_enum(out, &spec);
        }
    }
}

const POLICY_SOURCE: &str = include_str!("../src/task_board/policy.rs");
const POLICY_GRAPH_SOURCE: &str = include_str!("../src/task_board/policy_graph.rs");
const POLICY_MODELS_SOURCE: &str = include_str!("../src/task_board/policy_graph/models.rs");
const POLICY_IDS_SOURCE: &str = include_str!("../src/task_board/policy_graph/ids.rs");
const POLICY_DEFAULTS_SOURCE: &str = include_str!("../src/task_board/policy_graph/defaults.rs");
const POLICY_STORE_SOURCE: &str = include_str!("../src/task_board/policy_graph/store.rs");
const POLICY_SCENARIO_SOURCE: &str = include_str!("../src/task_board/policy_graph/scenario.rs");
const POLICY_REPLAY_SOURCE: &str = include_str!("../src/task_board/policy_graph/replay.rs");
const SUMMARIES_SOURCE: &str = include_str!("../src/daemon/protocol/summaries.rs");
const SHARED_DAEMON_SOURCE: &str = include_str!("../crates/harness-protocol/src/daemon.rs");
const HOOKS_PAYLOADS_SOURCE: &str = include_str!("../src/hooks/protocol/payloads.rs");
const SUMMARIES_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SummariesWireTypes.generated.swift";
/// summaries.rs is a 51-type mega-file whose session/observe/timeline/github
/// types are foundation-entangled (reference unmigrated daemon-state and
/// observe types). This allow-list surfaces only the self-contained
/// health/readiness/control/log-level cluster - clean structs over primitives -
/// as the first bottom-up slice; the rest migrate as their dependencies do.
const SUMMARIES_EMIT_ONLY: &[&str] = &[
    "HealthResponse",
    "DaemonControlResponse",
    "LogLevelResponse",
    "SetLogLevelRequest",
    "HostBridgeReconfigureRequest",
    // github diagnostics sub-cluster: GitHubApiDiagnostics (decoded by the app's
    // githubStatus()) + its three nested diagnostics structs. Self-contained over
    // primitives + each other. DaemonDiagnosticsReport stays out - it nests the
    // foundation-entangled manifest/launch-agent/acp-probe/audit types.
    "GitHubApiDiagnostics",
    "GitHubRateBucketDiagnostics",
    "GitHubCooldownDiagnostics",
    "GitHubOperationSpendDiagnostics",
    // observer summary cluster (ObserverSummary nests inside SessionDetail.observer):
    // ObserverOpenIssue is the first wire consumer of the observe enums
    // (IssueSeverity/IssueCategory/IssueCode/FixSafety). generate-only - the rich
    // hand models (String-typed enums, optional Vecs, ObserverOpenIssue renamed to
    // ObserverIssueSummary) stay until the SessionDetail reroute adopts them.
    "ObserverSummary",
    "ObserverOpenIssue",
    "ObserverActiveWorker",
    "ObserverAgentSessionSummary",
    // SessionSummary: the core dashboard session type and biggest SessionDetail
    // member. References SessionStatus (bare) + SessionMetricsWire +
    // PendingLeaderTransferWire, all generated in the session-state leaf. generate
    // -only - the rich hand SessionSummary keeps Int metrics and decodes via convert
    // until the SessionDetail reroute.
    "SessionSummary",
    // agent tool-activity cluster (AgentToolActivitySummary nests in SessionDetail.
    // agent_activity): pulls AgentPendingUserPrompt, which nests the hooks
    // AskUserQuestionPrompt/Option (from payloads.rs). All clean structs - generate
    // -only; the hand models rename the hooks types (AgentPendingUserPromptQuestion/
    // Option) and AgentPendingUserPrompt carries a legacy message-synthesis init.
    "AskUserQuestionOption",
    "AskUserQuestionPrompt",
    "AgentPendingUserPrompt",
    "AgentToolActivitySummary",
    // project/worktree rollup: ProjectSummary (the project list row) nests
    // Vec<WorktreeSummary>. Clean structs over primitives, generate-only.
    "WorktreeSummary",
    "ProjectSummary",
    // timeline pagination cursor + the window request that nests it. TimelineWindow
    // Response is held back - it nests Option<Vec<TimelineEntry>>, and TimelineEntry
    // is referenced bare by the codex wire types (suffixing it would ripple them).
    "TimelineCursor",
    "TimelineWindowRequest",
    // TimelineEntry: the high-traffic timeline row (payload: serde_json::Value ->
    // JSONValue). Suffixed to TimelineEntryWire - the codex CodexTranscriptResponseWire
    // referenced the hand TimelineEntry bare, so regenerating repoints it to the wire
    // and the codex mapping gains a map step (its comment predicted this).
    "TimelineEntry",
    // with TimelineEntry generated, the two responses that nest it unblock: the
    // window response (entries + before/after cursors) and the acp transcript.
    "TimelineWindowResponse",
    "AcpTranscriptResponse",
    // StreamEvent: the SSE envelope (event/recordedAt/sessionId + free-form payload
    // serde_json::Value -> JSONValue). Clean, same-named hand mirror, generate-only.
    "StreamEvent",
    // SessionDetail: the capstone aggregate every session-mutation endpoint returns. All six
    // members are generated now (session/agents/tasks/signals/observer/agent_activity), so the
    // wire references each member's *Wire and the hand init(wire:) maps the whole tree.
    "SessionDetail",
    // session push-event payloads: the watch-loop frames the Monitor decodes from the stream.
    // Each nests already-generated member wires (project/session summary, session detail, timeline
    // entry, signal record, observer, agent activity), so the maps reuse those member maps.
    "SessionsUpdatedPayload",
    "SessionsUpdatedDeltaPayload",
    "SessionUpdatedPayload",
    "SessionExtensionsPayload",
];
const OBSERVE_CLASSIFICATION_SOURCE: &str = include_str!("../src/observe/types/classification.rs");
const OBSERVE_ISSUE_CODE_SOURCE: &str = include_str!("../src/observe/types/issue_code.rs");
const OBSERVE_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ObserveWireTypes.generated.swift";
/// observe::types classification leaf: the foundation enums the summaries issue
/// cluster references. Only the four DECODE enums the app reuses are emitted -
/// ObserverIssueSummary decodes IssueSeverity/IssueCategory/IssueCode/FixSafety
/// as String today, and their typed form unblocks the summaries migration. The
/// allow-list skips MessageRole (Serialize-only), SourceTool (no rename_all, so
/// its wire values stay PascalCase the generator does not emit), and Confidence
/// (no Swift consumer yet).
const OBSERVE_EMIT_ONLY: &[&str] = &["IssueSeverity", "IssueCategory", "IssueCode", "FixSafety"];
const SESSION_STATE_SOURCE: &str = include_str!("../src/session/types/state.rs");
const SESSION_AGENTS_SOURCE: &str = include_str!("../src/session/types/agents.rs");
const SESSION_STATE_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionStateWireTypes.generated.swift";
/// session/types foundation leaf for the SessionSummary dep graph: SessionStatus
/// (lifecycle enum) + SessionMetrics (rollup counts) from state.rs, and
/// PendingLeaderTransfer from agents.rs. SessionStatus is adopted bare - a closed
/// string enum whose 5 cases match the hand enum exactly, so the generated form
/// replaces the hand decl (its `title` stays in an extension). SessionMetrics and
/// PendingLeaderTransfer take the Wire suffix (the hand SessionMetrics types its
/// counts as Int over the wire u32; PendingLeaderTransfer is a thin mirror but a
/// struct, so it can only adopt once SessionSummary reroutes off convertFromSnakeCase).
/// agents.rs also holds try_from/untagged types (AgentRegistration/AgentStatus) - the
/// emit-only list excludes them, and the symbol-table pass only reads metadata, so
/// the blocked shapes never reach the panic-prone emit builders. SessionState stays
/// out - it has no Swift mirror.
const SESSION_STATE_EMIT_ONLY: &[&str] =
    &["SessionStatus", "SessionMetrics", "PendingLeaderTransfer"];
const GIT_IDENTITY_DEFAULTS_SOURCE: &str =
    include_str!("../src/task_board/git_identity_defaults.rs");
const OPENROUTER_SOURCE: &str = include_str!("../src/daemon/protocol/openrouter_models.rs");
const VOICE_SOURCE: &str = include_str!("../src/daemon/protocol/voice.rs");
const AUDIT_SOURCE: &str = include_str!("../src/daemon/protocol/audit.rs");
// The shared protocol package owns the managed terminal snapshot/request types
// and their defaults. Runtime-only PTY behavior remains in daemon/agent_tui.
const AGENT_TUI_MODEL_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/tui.rs");
const AGENT_TUI_RUNTIME_MODEL_SOURCE: &str = include_str!("../src/daemon/agent_tui/model.rs");
const AGENT_TUI_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AgentTuiWireTypes.generated.swift";
const AGENT_TUI_EMIT_ONLY: &[&str] = &[
    "TerminalScreenSnapshot",
    "AgentTuiSize",
    "AgentTuiLaunchProfile",
    "AgentTuiStatus",
    "AgentTuiStartRequest",
    "AgentTuiResizeRequest",
    "AgentTuiListResponse",
    "AgentTuiSnapshot",
];
const AGENT_TUI_INPUT_SOURCE: &str = include_str!("../src/daemon/agent_tui/input_request.rs");
const AGENT_TUI_INPUT_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AgentTuiInputRequestWireTypes.generated.swift";
// The agent-tui input request body (sendManagedAgentInput). The public AgentTuiInputRequest has
// #[serde(try_from = "RawAgentTuiInputRequest")], so the generator targets the private
// RawAgentTuiInputRequest proxy, emitted as AgentTuiInputRequestWire. Its input/sequence fields
// reference the decoder-agnostic hand AgentTuiInput/AgentTuiInputSequence bare (single-word keys).
const AGENT_TUI_INPUT_EMIT_ONLY: &[&str] = &["RawAgentTuiInputRequest"];
// codex: the run snapshot subtree decodes inside ManagedAgentSnapshot.Codex;
// the file also defines its own default fn (default_codex_agent_role ->
// SessionRole::Worker) resolved by the symbol table. SessionRole and
// TimelineEntry are referenced-not-defined, so they stay unsuffixed (the hand
// Swift types).
const CODEX_SOURCE: &str = include_str!("../src/daemon/protocol/codex.rs");
// session_requests: clean serde request/response structs. Seven types are
// SKIP_TYPES (no Swift mirror); the rest reference session::types enums that
// already exist hand-written in Swift, so they stay unsuffixed references.
const SESSION_REQUESTS_SOURCE: &str = include_str!("../src/daemon/protocol/session_requests.rs");
// reviews/enums.rs: the GitHub review wire enums. Adopted directly (bare-named,
// replacing the hand HarnessMonitorReviewsEnums file) rather than wire/model
// split, since a string enum's generated form is a drop-in for the hand one.
// Most are open enums (OPEN_STRING_ENUMS); ReviewAuthorAssociation is the lone
// closed one, mirroring its closed Rust enum and exhaustive Swift consumers.
const REVIEWS_ENUMS_SOURCE: &str = include_str!("../src/reviews/enums.rs");
// reviews leaves: small clean request/response structs (plus two enums). Split
// into suffixed *Wire types; the hand models live in scattered/mixed Swift
// files, so this is additive, not direct adoption. body_update's response
// carries a DateTime (-> String) and the open ReviewsBodyUpdateOutcome.
const REVIEWS_AVATAR_SOURCE: &str = include_str!("../src/reviews/avatar.rs");
const REVIEWS_BODY_UPDATE_SOURCE: &str = include_str!("../src/reviews/body_update.rs");
const REVIEWS_FILE_COMMENT_SOURCE: &str = include_str!("../src/reviews/file_comment.rs");
const REVIEWS_THREAD_RESOLVE_SOURCE: &str = include_str!("../src/reviews/review_thread_resolve.rs");
// reviews files-core: the file list/patch/preview/blob/viewed surface plus the
// two cross-wire facade types from service.rs/local_clone.rs. preview.rs carries
// no types (the preview structs live in mod.rs) but supplies the
// `preview_line_limit` default fn and its const. service.rs/local_clone.rs each
// expose one wire type (FilesLargeDiffStrategy, LocalCloneListEntry); their
// daemon-internal serde types are SKIP_TYPES.
const REVIEWS_FILES_MOD_SOURCE: &str = include_str!("../src/reviews/files/mod.rs");
const REVIEWS_FILES_BLOB_SOURCE: &str = include_str!("../src/reviews/files/blob.rs");
const REVIEWS_FILES_VIEWED_SOURCE: &str = include_str!("../src/reviews/files/viewed.rs");
const REVIEWS_FILES_PREVIEW_SOURCE: &str = include_str!("../src/reviews/files/preview.rs");
const REVIEWS_FILES_SERVICE_SOURCE: &str = include_str!("../src/reviews/files/service.rs");
const REVIEWS_FILES_LOCAL_CLONE_SOURCE: &str = include_str!("../src/reviews/files/local_clone.rs");
// reviews timeline: the PR timeline entries. ReviewTimelineEntry is internally
// tagged (tag="kind") wrapping newtype entry structs (the generator re-inlines
// the payload alongside the tag); the entries carry chrono DateTime, a boxed
// SimpleActorEventEntry, and a JsonValue raw payload - all handled.
const REVIEWS_TIMELINE_TYPES_SOURCE: &str = include_str!("../src/reviews/timeline/types.rs");
const REVIEWS_TIMELINE_MOD_SOURCE: &str = include_str!("../src/reviews/timeline/mod.rs");
// reviews types core: the query/item/check/action/policy request-response
// surface. The public umbrella re-exports the split action and policy modules,
// so generation needs all three files. The custom default fns it references live
// in src/reviews/logic.rs (the defaults source). GitHubMergeMethod is
// referenced-not-defined (renamed to the hand type); ReviewAuthorAssociation
// references the adopted closed enum.
const REVIEWS_TYPES_SOURCE: &str = include_str!("../src/reviews/types.rs");
const REVIEWS_TYPES_ACTIONS_SOURCE: &str = include_str!("../src/reviews/types/actions.rs");
const REVIEWS_TYPES_POLICY_SOURCE: &str = include_str!("../src/reviews/types/policy.rs");
const REVIEWS_LOGIC_SOURCE: &str = include_str!("../src/reviews/logic.rs");
// websocket: the JSON-RPC-ish transport envelope. The five self-contained frame
// types (request/response/error/push/chunk) generate; the three config/probe/
// inspect payloads reference unmigrated persona/runtime/acp types and are SKIP'd
// until those subsystems land. serde_json::Value -> JSONValue, the request's
// trace_context is a String dict.
const WEBSOCKET_SOURCE: &str = include_str!("../src/daemon/protocol/websocket.rs");
const WEBSOCKET_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/WebSocketWireTypes.generated.swift";
const WEBSOCKET_EMIT_ONLY: &[&str] = &[
    "WsRequest",
    "WsResponse",
    "WsErrorPayload",
    "WsPushEvent",
    "WsChunkFrame",
    "WsConfigPayload",
];
// session tasks: the WorkItem task-board core + its review-flow structs. Fully
// self-contained (no imports; fields are primitives or in-file types). 10 structs
// generate as *Wire (generate-only); the 6 closed enums (TaskSeverity/TaskStatus/
// TaskQueuePolicy/TaskSource/ReviewVerdict/ReviewPointState) are SKIP'd - they
// carry app divergences (TaskStatus legacy-tolerant decode, TaskSeverity .title)
// so the structs reference the existing bare Swift hand enums. ReviewPoint is also
// SKIP'd (bare hand) to avoid rippling its bare use in SessionRequestsWireTypes.
const SESSION_TASKS_SOURCE: &str = include_str!("../src/session/types/tasks.rs");
const TASK_BOARD_PROTOCOL_SOURCE: &str = include_str!("../src/daemon/protocol/task_board.rs");
const TASK_BOARD_TYPES_SOURCE: &str = include_str!("../src/task_board/types.rs");
const TASK_BOARD_LANE_SOURCE: &str = include_str!("../src/task_board/lane.rs");
const TASK_BOARD_PROGRESS_ROLLUP_SOURCE: &str =
    include_str!("../src/task_board/progress_rollup.rs");
const TASK_BOARD_WORKFLOW_SOURCE: &str = include_str!("../src/task_board/automation/workflow.rs");
const TASK_BOARD_ENUMS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardEnums.generated.swift";
// The task-board foundation enums that every item/summary/request references.
// TaskBoardItemKind stays hand-written because its Unknown(String) variant
// carries a raw value the string-enum emitter cannot model. TaskBoardStatus and
// AgentMode emit open; TaskBoardPriority and TaskBoardWorkflowKind are closed.
const TASK_BOARD_ENUMS_EMIT_ONLY: &[&str] = &[
    "TaskBoardStatus",
    "TaskBoardPriority",
    "AgentMode",
    "TaskBoardWorkflowKind",
];
const TASK_BOARD_SUMMARY_SOURCE: &str = include_str!("../src/task_board/summary.rs");
const TASK_BOARD_SUMMARY_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardSummaryWireTypes.generated.swift";
// The audit, project and machine summary structs - all over primitives plus the
// adopted TaskBoardStatus/TaskBoardAgentMode enums. The sync summary cluster is
// excluded (it needs the external-sync provider/operation sub-graph first).
const TASK_BOARD_SUMMARY_EMIT_ONLY: &[&str] = &[
    "TaskBoardAuditSummary",
    "TaskBoardStatusCount",
    "TaskBoardProjectSummary",
    "TaskBoardMachineSummary",
];
const TASK_BOARD_ITEM_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardItemWireTypes.generated.swift";
// The core TaskBoardItem and its nested structs/enums from types.rs, plus the
// items-list and explicit-position response wrappers from the protocol facade.
// References the adopted TaskBoardStatus/TaskBoardPriority/TaskBoardAgentMode/
// TaskBoardWorkflowKind enums bare; the two closed enums here
// (ExternalRefProvider, TaskBoardWorkflowStatus) take the suffix. The *Wire types
// own the faithful daemon decode, while the workflow source resolves the
// workflow-kind serde default without emitting the rest of its graph.
const TASK_BOARD_ITEM_EMIT_ONLY: &[&str] = &[
    "TaskBoardItem",
    "TaskBoardLaneOrigin",
    "ExternalRef",
    "ExternalRefSyncState",
    "ExternalRefProvider",
    "PlanningState",
    "TaskBoardWorkflowState",
    "TaskBoardWorkflowStatus",
    "TaskUsage",
    "TaskBoardProgressRollup",
    "TaskBoardListItemsResponse",
    "TaskBoardItemPositionSnapshot",
    "TaskBoardShiftedItemRevision",
    "TaskBoardItemPositionMutationResponse",
];
const TASK_BOARD_MACHINES_SOURCE: &str = include_str!("../src/task_board/machines.rs");
const TASK_BOARD_MACHINES_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardMachineWireTypes.generated.swift";
// The host Machine struct (Swift hand TaskBoardHostMachine); references the adopted
// TaskBoardAgentMode bare. MachineRegistry is excluded by the allow-list.
const TASK_BOARD_MACHINES_EMIT_ONLY: &[&str] = &["Machine"];
const TASK_BOARD_PLANNING_SOURCE: &str = include_str!("../src/task_board/planning.rs");
const TASK_BOARD_PLANNING_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardPlanningWireTypes.generated.swift";
// The planning transition (planning.rs) and its response wrapper (protocol facade),
// which carries the rerouted TaskBoardItemWire. PlanApprovalGate (struct-variant
// tagged) and the rest of the protocol facade are excluded by the allow-list.
const TASK_BOARD_PLANNING_EMIT_ONLY: &[&str] = &["PlanningTransition", "TaskBoardPlanningResponse"];
const TASK_BOARD_EVALUATION_SOURCE: &str = include_str!("../src/task_board/evaluation.rs");
const TASK_BOARD_EVALUATION_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardEvaluationWireTypes.generated.swift";
// The evaluate-endpoint summary, its records, outcome enum and signal-failure
// (evaluation.rs). The record carries the rerouted TaskBoardItemWire and references
// TaskStatus/TaskBoardStatus/TaskBoardWorkflowStatus bare. The build helpers and the
// rest of evaluation.rs are excluded by the allow-list.
const TASK_BOARD_EVALUATION_EMIT_ONLY: &[&str] = &[
    "TaskBoardEvaluationSummary",
    "TaskBoardEvaluationRecord",
    "TaskBoardEvaluationOutcome",
    "EvaluationSignalFailure",
];
const TASK_BOARD_DISPATCH_SOURCE: &str = include_str!("../src/task_board/dispatch.rs");
const TASK_BOARD_STEPS_SOURCE: &str = include_str!("../src/daemon/protocol/task_board_steps.rs");
const TASK_BOARD_DISPATCH_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardDispatchWireTypes.generated.swift";
// The dispatch-endpoint execution summary and its plan/intent graph (dispatch.rs).
// The internally-tagged enums emit as Swift enums with associated values; references
// to TaskBoardItem/ExternalRef/TaskStatus/TaskSeverity/TaskSource/AgentMode resolve
// bare or via the item-cluster *Wire, and PolicyDecision/PolicyReasonCode resolve via
// the imported HarnessMonitorPolicyModels (NOT re-emitted here - planning.rs is sourced
// only for PlanApprovalBlockReason). The lifecycle/failure sub-graphs are dropped via
// OMITTED_WIRE_FIELDS.
const TASK_BOARD_DISPATCH_EMIT_ONLY: &[&str] = &[
    "DispatchExecutionSummary",
    "DispatchPlan",
    "DispatchAppliedTask",
    "DispatchReadiness",
    "DispatchBlockReason",
    "SessionIntent",
    "TaskCreationIntent",
    "WorkerIntent",
    "ReviewerIntent",
    "EvaluatorIntent",
    "FollowUpPhase",
    "PlanApprovalBlockReason",
    "TaskBoardDispatchDeliverRequest",
    "TaskBoardDispatchDeliverResponse",
    "TaskBoardDispatchPickRequest",
    "TaskBoardDispatchPickResponse",
    "TaskBoardDispatchPickSelection",
];
const POLICY_CANVAS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/PolicyCanvasWireTypes.generated.swift";
// The policy-canvas read types in the task_board.rs facade. The rest of that file
// (flatten, alias and struct-variant-tagged types) is excluded by the allow-list,
// so it never reaches the panic-prone builders.
const POLICY_CANVAS_EMIT_ONLY: &[&str] = &[
    "PolicyCanvasSummary",
    "PolicyCanvasWorkspaceResponse",
    "PolicyCanvasExportResponse",
];
const ACP_MODELS_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/acp/models.rs");
// The MCP server types a start request carries. They live beside models.rs
// rather than in it, so every module that emits a type referencing them has to
// list this source too or the reference resolves to nothing.
const ACP_MCP_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/acp/mcp.rs");
const ACP_PROBE_SOURCE: &str = ACP_MODELS_SOURCE;
const ACP_PROBE_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpProbeWireTypes.generated.swift";
// The runtime-doctor probe response (probe.rs) backing /v1/runtimes/probe and the
// MonitorConfiguration.runtimeProbe field. AcpAuthState is a closed single-word
// snake_case enum (ready/unknown/unavailable) - decoder-agnostic, so it is referenced
// bare (the hand Swift enum) rather than suffixed. The probe-cache internals carry no
// serde derive, so the allow-list keeps them out of the emit builders.
const ACP_PROBE_EMIT_ONLY: &[&str] = &["AcpRuntimeProbeResponse", "AcpRuntimeProbe"];
const AGENT_PERSONA_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AgentPersonaWireTypes.generated.swift";
// The persona definition (agents.rs) backing the MonitorConfiguration.personas field.
// PersonaSymbol is internally tagged on "type" (sf_symbol/asset, both newtype-shaped
// `{ name }` variants) and emits as a Swift enum with associated values. The allow-list
// keeps the try_from/untagged agents.rs types (AgentRegistration/AgentStatus) out of the
// emit builders - the same file already parses for the session-state module.
const AGENT_PERSONA_EMIT_ONLY: &[&str] = &["AgentPersona", "PersonaSymbol"];
const RUNTIME_MODELS_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/runtime_models.rs");
const RUNTIME_MODELS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/RuntimeModelCatalogWireTypes.generated.swift";
// The runtime model catalog (models/mod.rs) backing MonitorConfiguration.runtimeModels
// and AcpAgentDescriptor.modelCatalog. RuntimeModelTier (fast/balanced/max) and EffortKind
// (none/thinking_budget/reasoning_effort) are closed string enums the hand Swift declares
// with explicit snake_case raw values, so the wire references them bare; the effort_kind
// default resolves to .none via the same-file defaults source.
const RUNTIME_MODELS_EMIT_ONLY: &[&str] = &["RuntimeModelCatalog", "RuntimeModel"];
const ACP_DESCRIPTOR_SOURCE: &str = ACP_MODELS_SOURCE;
const ACP_DESCRIPTOR_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpAgentDescriptorWireTypes.generated.swift";
// The acp agent descriptor (catalog/mod.rs) backing MonitorConfiguration.acpAgents. The
// daemon-only spawn_configuration/session_configuration fields (their AcpSpawnConfiguration
// /transport sub-enums are not modelled by the app) are dropped via OMITTED_WIRE_FIELDS, so
// the allow-list need only emit the descriptor and its DoctorProbe; model_catalog reuses the
// RuntimeModelCatalogWire and capabilities is the CapabilityTag = String alias (TYPE_RENAMES).
const ACP_DESCRIPTOR_EMIT_ONLY: &[&str] = &["AcpAgentDescriptor", "DoctorProbe"];
const ACP_INSPECT_WIRE_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/acp/snapshot_wire.rs");
const ACP_INSPECT_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpInspectWireTypes.generated.swift";
// The acp inspect response backing /v1/managed-agents/acp/inspect. The rich AcpAgentSnapshot
// /AcpAgentInspectSnapshot carry NO serde derive (borrowed-serialize optimization), so the
// faithful decode shape is the owned `AcpAgentInspectSnapshotDecode` in snapshot_wire.rs - we
// emit THAT under the AcpAgentInspectSnapshotWire name (TYPE_RENAMES) and rename the response's
// `AcpAgentInspectSnapshot` field reference to it. managed_agent_family (ManagedAgentKind) is
// dropped via OMITTED_WIRE_FIELDS (the hand snapshot does not model it), so the only deps are
// primitives (plus the serde-derived AcpAgentHandshake from models.rs). available's
// default_acp_inspect_available -> true resolves from models.rs.
const ACP_INSPECT_EMIT_ONLY: &[&str] = &[
    "AcpAgentInspectResponse",
    "AcpAgentInspectSnapshotDecode",
    "AcpAgentHandshake",
    "AcpAgentSessionState",
    "AcpSessionConfigOptionState",
];
const ACP_PERMISSION_ITEM_SOURCE: &str = ACP_MODELS_SOURCE;
const ACP_PERMISSION_WIRE_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/acp/permission_wire.rs");
const ACP_PERMISSION_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpPermissionWireTypes.generated.swift";
// The acp permission batch/item carried by AcpAgentSnapshot.pending_permission_batches. The
// public AcpPermissionBatch has no serde derive (borrowed-serialize), so its owned
// AcpPermissionBatchDecode is emitted as AcpPermissionBatchWire; managed_agent_family
// (ManagedAgentKind) is dropped. AcpPermissionItem carries its derive directly; its
// options: Vec<PermissionOption> (external agent_client_protocol crate, the app models it as
// raw JSON) maps to [JSONValue] via TYPE_RENAMES, and tool_call is serde_json::Value -> JSONValue.
const ACP_PERMISSION_EMIT_ONLY: &[&str] = &[
    "AcpPermissionItem",
    "AcpPermissionBatchDecode",
    "AcpPermissionDecision",
];
const ACP_SNAPSHOT_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpAgentSnapshotWireTypes.generated.swift";
// The full acp managed-agent snapshot, the Acp variant of ManagedAgentSnapshot. Generated from
// its owned AcpAgentSnapshotDecode (the public type has no serde derive); managed_agent_family
// is dropped, pending_permission_batches reuses AcpPermissionBatchWire, and status is a
// JSONValue passthrough (JSON_PASSTHROUGH_FIELDS) - the map re-decodes the flattened AgentStatus
// plus the disconnect reason/stderr_tail the daemon nests in the status object.
const ACP_SNAPSHOT_EMIT_ONLY: &[&str] = &["AcpAgentSnapshotDecode"];
const ACP_START_REQUEST_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/managed_agents/acp/request_wire.rs");
const ACP_START_REQUEST_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpAgentStartRequestWireTypes.generated.swift";
// The acp managed-agent start request body. The public AcpAgentStartRequest has no serde derive
// (hand Serialize/Deserialize via proxy structs); its owned AcpAgentStartRequestDecode carries
// the derive and emits as AcpAgentStartRequestWire. descriptor_id maps to the hand `agent` field;
// role defaults via default_acp_role (resolved from models.rs).
const ACP_START_REQUEST_EMIT_ONLY: &[&str] = &[
    "AcpAgentStartRequestDecode",
    "AcpEndpoint",
    "AcpMcpServer",
    "AcpMcpEnvVariable",
    "AcpMcpHttpHeader",
];
const MANAGED_AGENTS_SOURCE: &str = include_str!("../src/daemon/protocol/managed_agents.rs");
const MANAGED_AGENTS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ManagedAgentSnapshotWireTypes.generated.swift";
// The managed-agent snapshot umbrella + its list response. ManagedAgentSnapshot is adjacently
// tagged (kind + snapshot) over the three transport snapshots - Terminal/Codex resolve to the
// already-generated AgentTuiSnapshotWire/CodexRunSnapshotWire, and Acp resolves to the
// AcpAgentSnapshotWire (TYPE_RENAMES from the public no-derive AcpAgentSnapshot). The return
// type of nearly every managed-agent endpoint.
const MANAGED_AGENTS_EMIT_ONLY: &[&str] = &["ManagedAgentSnapshot", "ManagedAgentListResponse"];
const DAEMON_STATE_SOURCE: &str = include_str!("../src/daemon/state/mod.rs");
const DAEMON_LAUNCHD_SOURCE: &str = include_str!("../src/daemon/launchd/mod.rs");
const DAEMON_STATE_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/DaemonStateWireTypes.generated.swift";
// The /v1/diagnostics report (DaemonDiagnosticsReport from summaries.rs) and the daemon-state
// cluster it nests: the manifest tree (state/mod.rs DaemonManifest -> HostBridgeManifest ->
// HostBridgeCapabilityManifest, plus DaemonBinaryStamp), the workspace diagnostics
// (DaemonDiagnostics -> DaemonAuditEvent), and the launchd LaunchAgentStatus. health and
// github_api resolve to the already-generated HealthResponseWire/GitHubApiDiagnosticsWire
// (bare suffixed refs). acp_runtime_probe and DaemonManifest.ownership are dropped via
// OMITTED_WIRE_FIELDS - the hand DaemonDiagnosticsReport/DaemonManifest never model them.
const DAEMON_STATE_EMIT_ONLY: &[&str] = &[
    "DaemonDiagnosticsReport",
    "DaemonManifest",
    "HostBridgeManifest",
    "HostBridgeCapabilityManifest",
    "DaemonBinaryStamp",
    "DaemonAuditEvent",
    "DaemonDiagnostics",
    "LaunchAgentStatus",
];
const SHARED_AGENT_MODELS_SOURCE: &str =
    include_str!("../crates/harness-protocol/src/agent_models.rs");
const SESSION_SIGNAL_SOURCE: &str = SHARED_AGENT_MODELS_SOURCE;
const SESSION_EVENTS_SOURCE: &str = include_str!("../src/session/types/events.rs");
const SESSION_SIGNAL_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionSignalWireTypes.generated.swift";
// The session signal record (events.rs SessionSignalRecord) + the runtime signal cluster it nests
// (signal/mod.rs Signal -> SignalPayload/DeliveryConfig, SignalAck), the SessionDetail.signals
// member. SignalPriority/AckResult/SessionSignalStatus are single-word snake_case enums the hand
// Swift declares with matching raw values (SessionSignalStatus even keeps the `acknowledged`
// legacy-alias decode) - decoder-agnostic, so the wire references them BARE. SignalPayload.metadata
// is serde_json::Value -> JSONValue.
const SESSION_SIGNAL_EMIT_ONLY: &[&str] = &[
    "SessionSignalRecord",
    "Signal",
    "SignalPayload",
    "DeliveryConfig",
    "SignalAck",
];
const AGENT_REGISTRATION_WIRE_SOURCE: &str = include_str!("../src/session/types/agents/wire.rs");
const AGENT_RUNTIME_SOURCE: &str = SHARED_AGENT_MODELS_SOURCE;
const AGENT_REGISTRATION_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AgentRegistrationWireTypes.generated.swift";
// The SessionDetail.agents member. The public AgentRegistration is `#[serde(try_from)]` its owned
// wire::AgentRegistrationWire (agents/wire.rs) - that already-named *Wire companion carries the
// flat decode shape, so the allow-list emits it directly (no Wire suffix - it is named that).
// runtime is the untagged RuntimeKind (bare string or {kind,id}); the hand init collapses it to a
// String, so the wire emits it as a JSON_PASSTHROUGH JSONValue the map re-reads. SessionRole,
// AgentStatus (hybrid bare-string-or-{state} decode) and ManagedAgentKind are decoder-agnostic
// hand enums referenced bare; persona reuses AgentPersonaWire; runtime_capabilities suffixes
// RuntimeCapabilities + HookIntegrationDescriptor (agents/runtime/mod.rs).
const AGENT_REGISTRATION_EMIT_ONLY: &[&str] = &[
    "AgentRegistrationWire",
    "RuntimeCapabilities",
    "HookIntegrationDescriptor",
];
const TASK_BOARD_CREDENTIAL_SOURCE: &str = include_str!("../src/task_board/runtime_config.rs");
const TASK_BOARD_CREDENTIAL_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardCredentialWireTypes.generated.swift";
// The three token-sync response bodies (GitHub/Todoist/OpenRouter) the orchestrator credential
// endpoints return - tiny bool/count structs. The big git-runtime-config tree and the request
// bodies in this file stay out of the allow-list (requests are encode-only).
const TASK_BOARD_CREDENTIAL_EMIT_ONLY: &[&str] = &[
    "TaskBoardGitHubTokensSyncResponse",
    "TaskBoardTodoistTokenSyncResponse",
    "TaskBoardOpenRouterTokenSyncResponse",
];
const BRIDGE_STATUS_SOURCE: &str = include_str!("../src/daemon/bridge/types.rs");
const BRIDGE_STATUS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/BridgeStatusWireTypes.generated.swift";
// The host-bridge reconfigure response (reconfigureHostBridge). capabilities reuses the
// already-generated HostBridgeCapabilityManifestWire (daemon-state cluster) bare; pid/uptime
// narrow UInt -> Int in the map. The bridge-internal/persisted types stay out of the allow-list.
const BRIDGE_STATUS_EMIT_ONLY: &[&str] = &["BridgeStatusReport"];
const SYNC_SUMMARY_SOURCE: &str = include_str!("../src/task_board/summary.rs");
const EXTERNAL_SYNC_SOURCE: &str = include_str!("../src/task_board/external/sync.rs");
const SYNC_SUMMARY_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardSyncSummaryWireTypes.generated.swift";
// The task_board sync summary (syncTaskBoard endpoint + nested in the orchestrator run summary).
// ExternalProvider/ExternalSyncAction are decoder-agnostic hand enums (TaskBoardExternalProvider/
// TaskBoardExternalSyncAction) referenced bare via TYPE_RENAMES; ExternalSyncOperation's
// changed_fields/unsupported_fields (Vec<ExternalSyncField> - the genuine no-Swift-mirror type) are
// dropped via OMITTED_WIRE_FIELDS to match the hand TaskBoardExternalSyncOperation.
const SYNC_SUMMARY_EMIT_ONLY: &[&str] = &[
    "TaskBoardSyncSummary",
    "TaskBoardProviderSyncSummary",
    "ExternalSyncOperation",
];
const GITHUB_CONFIG_SOURCE: &str = include_str!("../src/task_board/github/config.rs");
const GITHUB_CONFIG_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitHubProjectWireTypes.generated.swift";
// The GitHubProjectConfig sub-tree nested in TaskBoardOrchestratorSettings.github_project. The
// five structs suffix to *Wire; GitHubMergeMethod/GitHubAutomation ride bare via TYPE_RENAMES (the
// decoder-agnostic Swift TaskBoardGitHubMergeMethod/TaskBoardGitHubAutomation); checkout_path is the
// PathBuf the new ext maps to String; default_branch/default_branch_prefix come from the same file.
const GITHUB_CONFIG_EMIT_ONLY: &[&str] = &[
    "GitHubProjectConfig",
    "GitHubAutomationLabels",
    "GitHubRequestedReviewers",
    "GitHubAutomationToggles",
    "ProtectedPathRule",
];
const ORCHESTRATOR_TYPES_SOURCE: &str = include_str!("../src/task_board/orchestrator/types.rs");
const ORCHESTRATOR_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardOrchestratorWireTypes.generated.swift";
// The orchestrator settings + status tree (orchestratorStatus/start/stop/run-once + settings get/
// update). github_project rides the GitHubProjectConfigWire (TYPE_RENAMES on the alias); the run
// summary nests the sync/audit/dispatch/evaluation wires; Workflow/TickPhase/RunStatus enums and
// TaskBoardStatus/TaskBoardWorkflowStatus ride bare. policy.rs is a source so the policy_version
// default fn resolves POLICY_VERSION.
const ORCHESTRATOR_EMIT_ONLY: &[&str] = &[
    "TaskBoardOrchestratorSettings",
    "TaskBoardGitHubInboxConfig",
    "TaskBoardTodoistInboxConfig",
    "TaskBoardOrchestratorTickInfo",
    "TaskBoardOrchestratorRunSummary",
    "TaskBoardWorkflowExecutionCount",
    "TaskBoardOrchestratorStatus",
    "TaskBoardHeldDispatchSummary",
    "TaskBoardHeldDispatchItem",
];
const TASK_BOARD_AUTOMATION_STATUS_SOURCE: &str =
    include_str!("../src/task_board/automation/status.rs");
const TASK_BOARD_AUTOMATION_SETTINGS_SOURCE: &str =
    include_str!("../src/task_board/automation/settings.rs");
const TASK_BOARD_AUTOMATION_PROTOCOL_SOURCE: &str =
    include_str!("../src/daemon/protocol/task_board_automation.rs");
const TASK_BOARD_AUTOMATION_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardAutomationWireTypes.generated.swift";
// Independent compact status, paged history/detail/metrics reads, and local
// automation settings. PR7-owned host, repository-routing, admission, transport,
// and force-cancel types intentionally remain outside this allow-list.
const TASK_BOARD_AUTOMATION_EMIT_ONLY: &[&str] = &[
    "TaskBoardAutomationDesiredMode",
    "TaskBoardAutomationAdmissionState",
    "TaskBoardAutomationEffectiveState",
    "TaskBoardAutomationRunTrigger",
    "TaskBoardAutomationRunState",
    "TaskBoardAutomationRunOutcome",
    "TaskBoardAutomationScope",
    "TaskBoardAutomationQueueSummary",
    "TaskBoardAutomationRunInfo",
    "TaskBoardAutomationHistoryRequest",
    "TaskBoardAutomationHistoryResponse",
    "TaskBoardAutomationRunStage",
    "TaskBoardAutomationRunDetail",
    "TaskBoardAutomationMetrics",
    "TaskBoardAutomationSnapshot",
    "TaskBoardAutomationSchedulingSettings",
    "TaskBoardAutomationRetrySettings",
    "TaskBoardReviewerProfile",
    "TaskBoardReviewerRule",
    "TaskBoardReviewerSettings",
    "TaskBoardAutomationRunDetailRequest",
];
const GIT_RUNTIME_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitRuntimeWireTypes.generated.swift";
// The git runtime config tree (runtime-config get/update + secret handoff). The config/profile/
// signing-config/override structs come from runtime_config.rs; the prepare response wrapper comes
// from daemon/protocol/task_board.rs and nests the config wire. The signing mode rides bare through
// the decoder-agnostic TaskBoardGitSigningMode open enum.
const GIT_RUNTIME_EMIT_ONLY: &[&str] = &[
    "TaskBoardGitRuntimeConfig",
    "TaskBoardGitRuntimeProfile",
    "TaskBoardGitSigningConfig",
    "TaskBoardGitRepositoryOverride",
    "TaskBoardGitRuntimeSecretHandoffPrepareResponse",
];
const GIT_SIGNING_VERIFY_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitSigningVerifyWireTypes.generated.swift";
// The git signing verify outcome (git/signing/verify). An internally-tagged enum on "outcome" with
// a unit variant (skipped), a two-field struct variant (signed: mode + signature_kind) and a
// single-field struct variant (failed: message); the generator emits a Swift associated-value enum.
const GIT_SIGNING_VERIFY_EMIT_ONLY: &[&str] = &["TaskBoardGitSigningVerifyResponse"];
const ACP_EVENT_FRAME_SOURCE: &str = include_str!("../src/daemon/agent_acp/event_frame.rs");
const ACP_CONVERSATION_EVENT_SOURCE: &str = include_str!("../src/agents/runtime/event.rs");
const ACP_EVENT_BATCH_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpEventBatchWireTypes.generated.swift";
// The acp_events broadcast push frame + its conversation event. The frame's managed_agent_family is
// the bare ManagedAgentKind (the map validates it is acp); ConversationEvent.kind is the richly
// tagged ConversationEventKind the Swift side keeps opaque, so it rides through as JSONValue
// (JSON_PASSTHROUGH_FIELDS) and the event kind enum is never emitted.
const ACP_EVENT_BATCH_EMIT_ONLY: &[&str] = &["AcpEventBatchPayload", "ConversationEvent"];
const ACP_ACTIVE_SOURCE: &str = include_str!("../src/daemon/agent_acp/active.rs");
const ACP_INCIDENTS_SOURCE: &str =
    include_str!("../src/daemon/agent_acp/sandbox_proxy/incidents.rs");
const ACP_SANDBOX_PROXY_SOURCE: &str = include_str!("../src/daemon/agent_acp/sandbox_proxy.rs");
const ACP_INCIDENT_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AcpIncidentWireTypes.generated.swift";
// The ACP process/bridge incident + agents-reconciled push payloads (daemon-internal Serialize
// structs the daemon broadcasts). The reconciled payload nests AcpAgentSnapshotWire (TYPE_RENAMES)
// + AcpAgentInspectResponseWire; the process incident drops the daemon-only restart/backoff/
// quarantine booleans the Swift hand never models (OMITTED_WIRE_FIELDS).
const ACP_INCIDENT_EMIT_ONLY: &[&str] = &[
    "AcpProcessIncidentPayload",
    "AcpBridgeResyncIncidentPayload",
    "AcpAgentsReconciledPayload",
];
const LOCAL_CLONE_PROGRESS_SOURCE: &str =
    include_str!("../src/reviews/files/local_clone_progress_event.rs");
const LOCAL_CLONE_PROGRESS_OUTPUT: &str = "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewLocalCloneProgressWireTypes.generated.swift";
// The reviews local-clone progress push payload: an internally-tagged enum (tag = "kind") with
// struct variants the Swift hand ReviewLocalCloneProgress flattens. The operation rides the
// string-serialized LocalCloneOperationWire (clone/fetch); the map projects the enum to the flat
// hand struct.
const LOCAL_CLONE_PROGRESS_EMIT_ONLY: &[&str] =
    &["LocalCloneProgressEventPayload", "LocalCloneOperationWire"];

/// One Rust -> Swift wire-type module: the Rust sources whose serde types are
/// emitted, zero or more defaults sources informing decode defaults, a short
/// description woven into the generated header, and the checked-in output path
/// (relative to the repository root).
struct GeneratedModule {
    output: &'static str,
    description: &'static str,
    defaults: &'static [&'static str],
    sources: &'static [&'static str],
}

/// Every generated Swift wire-type module. Add an entry here to bring another
/// daemon subsystem under generation; `codegen` writes each file and
/// `codegen:check` fails when any drifts from its Rust sources.
#[allow(
    clippy::too_many_lines,
    reason = "the declarative generated-module inventory is easiest to audit as one table"
)]
fn modules() -> Vec<GeneratedModule> {
    vec![
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorPolicyModels/Generated/PolicyGraphWireTypes.generated.swift",
            description: "the Rust policy-graph wire types",
            defaults: &[POLICY_DEFAULTS_SOURCE],
            sources: &[
                POLICY_IDS_SOURCE,
                POLICY_SOURCE,
                POLICY_GRAPH_SOURCE,
                POLICY_MODELS_SOURCE,
                POLICY_STORE_SOURCE,
                POLICY_SCENARIO_SOURCE,
                POLICY_REPLAY_SOURCE,
            ],
        },
        GeneratedModule {
            output: SUMMARIES_OUTPUT,
            description: "the Rust daemon health, summary and tool-activity types",
            defaults: &[SUMMARIES_SOURCE],
            sources: &[
                SUMMARIES_SOURCE,
                SHARED_DAEMON_SOURCE,
                HOOKS_PAYLOADS_SOURCE,
            ],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitWireTypes.generated.swift",
            description: "the Rust task-board git identity sources",
            defaults: &[GIT_IDENTITY_DEFAULTS_SOURCE],
            sources: &[GIT_IDENTITY_DEFAULTS_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/OpenRouterWireTypes.generated.swift",
            description: "the Rust OpenRouter model catalog",
            defaults: &[],
            sources: &[OPENROUTER_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/VoiceWireTypes.generated.swift",
            description: "the Rust voice session protocol",
            defaults: &[VOICE_SOURCE],
            sources: &[VOICE_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AuditWireTypes.generated.swift",
            description: "the Rust audit events protocol",
            defaults: &[AUDIT_SOURCE],
            sources: &[AUDIT_SOURCE],
        },
        GeneratedModule {
            output: AGENT_TUI_OUTPUT,
            description: "the Rust managed terminal agent protocol",
            defaults: &[AGENT_TUI_MODEL_SOURCE],
            sources: &[AGENT_TUI_MODEL_SOURCE, AGENT_TUI_RUNTIME_MODEL_SOURCE],
        },
        GeneratedModule {
            output: AGENT_TUI_INPUT_OUTPUT,
            description: "the Rust managed terminal agent input request from its raw proxy",
            defaults: &[],
            sources: &[AGENT_TUI_INPUT_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/CodexWireTypes.generated.swift",
            description: "the Rust codex run protocol",
            defaults: &[CODEX_SOURCE],
            sources: &[CODEX_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionRequestsWireTypes.generated.swift",
            description: "the Rust session request protocol",
            defaults: &[SESSION_REQUESTS_SOURCE],
            sources: &[SESSION_REQUESTS_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsEnums.generated.swift",
            description: "the Rust reviews wire enums",
            defaults: &[],
            sources: &[REVIEWS_ENUMS_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsLeavesWireTypes.generated.swift",
            description: "the Rust reviews leaf request/response types",
            defaults: &[],
            sources: &[
                REVIEWS_AVATAR_SOURCE,
                REVIEWS_BODY_UPDATE_SOURCE,
                REVIEWS_FILE_COMMENT_SOURCE,
                REVIEWS_THREAD_RESOLVE_SOURCE,
            ],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsFilesWireTypes.generated.swift",
            description: "the Rust reviews file list, patch, preview, blob, viewed and local-clone types",
            defaults: &[REVIEWS_FILES_MOD_SOURCE, REVIEWS_FILES_PREVIEW_SOURCE],
            sources: &[
                REVIEWS_FILES_MOD_SOURCE,
                REVIEWS_FILES_BLOB_SOURCE,
                REVIEWS_FILES_VIEWED_SOURCE,
                REVIEWS_FILES_PREVIEW_SOURCE,
                REVIEWS_FILES_SERVICE_SOURCE,
                REVIEWS_FILES_LOCAL_CLONE_SOURCE,
            ],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsTimelineWireTypes.generated.swift",
            description: "the Rust reviews pull request timeline types",
            defaults: &[],
            sources: &[REVIEWS_TIMELINE_TYPES_SOURCE, REVIEWS_TIMELINE_MOD_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsTypesWireTypes.generated.swift",
            description: "the Rust reviews query, item, check, action and policy types",
            defaults: &[REVIEWS_LOGIC_SOURCE],
            sources: &[
                REVIEWS_TYPES_SOURCE,
                REVIEWS_TYPES_ACTIONS_SOURCE,
                REVIEWS_TYPES_POLICY_SOURCE,
            ],
        },
        GeneratedModule {
            output: WEBSOCKET_OUTPUT,
            description: "the Rust websocket transport frame types",
            defaults: &[],
            sources: &[SHARED_DAEMON_SOURCE, WEBSOCKET_SOURCE],
        },
        GeneratedModule {
            output: "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionTasksWireTypes.generated.swift",
            description: "the Rust session work-item and review-flow types",
            defaults: &[SESSION_TASKS_SOURCE],
            sources: &[SESSION_TASKS_SOURCE],
        },
        GeneratedModule {
            output: OBSERVE_OUTPUT,
            description: "the Rust observe issue classification enums",
            defaults: &[],
            sources: &[OBSERVE_CLASSIFICATION_SOURCE, OBSERVE_ISSUE_CODE_SOURCE],
        },
        GeneratedModule {
            output: SESSION_STATE_OUTPUT,
            description: "the Rust session lifecycle status, metrics and leader transfer",
            defaults: &[],
            sources: &[SESSION_STATE_SOURCE, SESSION_AGENTS_SOURCE],
        },
        GeneratedModule {
            output: POLICY_CANVAS_OUTPUT,
            description: "the Rust policy-canvas summary, workspace and export types",
            defaults: &[TASK_BOARD_PROTOCOL_SOURCE],
            sources: &[TASK_BOARD_PROTOCOL_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_ENUMS_OUTPUT,
            description: "the Rust task-board status, priority, agent-mode and workflow-kind enums",
            defaults: &[],
            sources: &[TASK_BOARD_TYPES_SOURCE, TASK_BOARD_WORKFLOW_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_SUMMARY_OUTPUT,
            description: "the Rust task-board audit, project and machine summaries",
            defaults: &[],
            sources: &[TASK_BOARD_SUMMARY_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_ITEM_OUTPUT,
            description: "the Rust task-board item, placement and list responses",
            defaults: &[],
            sources: &[
                TASK_BOARD_TYPES_SOURCE,
                TASK_BOARD_LANE_SOURCE,
                TASK_BOARD_PROTOCOL_SOURCE,
                TASK_BOARD_PROGRESS_ROLLUP_SOURCE,
                TASK_BOARD_WORKFLOW_SOURCE,
            ],
        },
        GeneratedModule {
            output: TASK_BOARD_MACHINES_OUTPUT,
            description: "the Rust task-board host machine type",
            defaults: &[],
            sources: &[TASK_BOARD_MACHINES_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_PLANNING_OUTPUT,
            description: "the Rust task-board planning transition and response",
            defaults: &[],
            sources: &[TASK_BOARD_PLANNING_SOURCE, TASK_BOARD_PROTOCOL_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_EVALUATION_OUTPUT,
            description: "the Rust task-board evaluation summary, records and outcome",
            defaults: &[],
            sources: &[TASK_BOARD_EVALUATION_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_DISPATCH_OUTPUT,
            description: "the Rust task-board dispatch execution summary, step routes and plan graph",
            defaults: &[],
            sources: &[
                TASK_BOARD_DISPATCH_SOURCE,
                TASK_BOARD_PLANNING_SOURCE,
                TASK_BOARD_STEPS_SOURCE,
            ],
        },
        GeneratedModule {
            output: ACP_PROBE_OUTPUT,
            description: "the Rust acp runtime-probe response",
            defaults: &[],
            sources: &[ACP_PROBE_SOURCE],
        },
        GeneratedModule {
            output: AGENT_PERSONA_OUTPUT,
            description: "the Rust agent persona definition and its symbol",
            defaults: &[],
            sources: &[SESSION_AGENTS_SOURCE],
        },
        GeneratedModule {
            output: RUNTIME_MODELS_OUTPUT,
            description: "the Rust runtime model catalog and its models",
            defaults: &[RUNTIME_MODELS_SOURCE],
            sources: &[RUNTIME_MODELS_SOURCE],
        },
        GeneratedModule {
            output: ACP_DESCRIPTOR_OUTPUT,
            description: "the Rust acp agent descriptor and its doctor probe",
            defaults: &[ACP_DESCRIPTOR_SOURCE],
            sources: &[ACP_DESCRIPTOR_SOURCE],
        },
        GeneratedModule {
            output: ACP_INSPECT_OUTPUT,
            description: "the Rust acp inspect response and its owned snapshot decode",
            defaults: &[ACP_MODELS_SOURCE],
            sources: &[ACP_MODELS_SOURCE, ACP_INSPECT_WIRE_SOURCE],
        },
        GeneratedModule {
            output: ACP_PERMISSION_OUTPUT,
            description: "the Rust acp permission batch and item",
            defaults: &[],
            sources: &[ACP_PERMISSION_ITEM_SOURCE, ACP_PERMISSION_WIRE_SOURCE],
        },
        GeneratedModule {
            output: ACP_SNAPSHOT_OUTPUT,
            description: "the Rust acp managed-agent snapshot from its owned decode struct",
            defaults: &[],
            sources: &[ACP_INSPECT_WIRE_SOURCE],
        },
        GeneratedModule {
            output: ACP_START_REQUEST_OUTPUT,
            description: "the Rust acp managed-agent start request from its owned decode struct",
            defaults: &[ACP_MODELS_SOURCE],
            sources: &[ACP_START_REQUEST_SOURCE, ACP_MODELS_SOURCE, ACP_MCP_SOURCE],
        },
        GeneratedModule {
            output: MANAGED_AGENTS_OUTPUT,
            description: "the Rust managed-agent snapshot umbrella and list response",
            defaults: &[],
            sources: &[MANAGED_AGENTS_SOURCE],
        },
        GeneratedModule {
            output: DAEMON_STATE_OUTPUT,
            description: "the Rust daemon diagnostics report, manifest and launch-agent state",
            defaults: &[DAEMON_STATE_SOURCE],
            sources: &[SUMMARIES_SOURCE, DAEMON_STATE_SOURCE, DAEMON_LAUNCHD_SOURCE],
        },
        GeneratedModule {
            output: SESSION_SIGNAL_OUTPUT,
            description: "the Rust session signal record and runtime signal cluster",
            defaults: &[],
            sources: &[SESSION_SIGNAL_SOURCE, SESSION_EVENTS_SOURCE],
        },
        GeneratedModule {
            output: AGENT_REGISTRATION_OUTPUT,
            description: "the Rust agent registration wire and runtime capabilities",
            defaults: &[],
            sources: &[AGENT_REGISTRATION_WIRE_SOURCE, AGENT_RUNTIME_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_CREDENTIAL_OUTPUT,
            description: "the Rust task-board orchestrator token-sync responses",
            defaults: &[],
            sources: &[TASK_BOARD_CREDENTIAL_SOURCE],
        },
        GeneratedModule {
            output: BRIDGE_STATUS_OUTPUT,
            description: "the Rust host-bridge reconfigure status report",
            defaults: &[],
            sources: &[BRIDGE_STATUS_SOURCE],
        },
        GeneratedModule {
            output: SYNC_SUMMARY_OUTPUT,
            description: "the Rust task-board sync summary and external operations",
            defaults: &[],
            sources: &[SYNC_SUMMARY_SOURCE, EXTERNAL_SYNC_SOURCE],
        },
        GeneratedModule {
            output: GITHUB_CONFIG_OUTPUT,
            description: "the Rust task-board github project config sub-tree",
            defaults: &[GITHUB_CONFIG_SOURCE],
            sources: &[GITHUB_CONFIG_SOURCE],
        },
        GeneratedModule {
            output: ORCHESTRATOR_OUTPUT,
            description: "the Rust task-board orchestrator settings and status tree",
            defaults: &[ORCHESTRATOR_TYPES_SOURCE],
            sources: &[ORCHESTRATOR_TYPES_SOURCE, POLICY_SOURCE],
        },
        GeneratedModule {
            output: TASK_BOARD_AUTOMATION_OUTPUT,
            description: "the independent Rust task-board automation status, history, metrics and settings types",
            defaults: &[
                TASK_BOARD_AUTOMATION_STATUS_SOURCE,
                TASK_BOARD_AUTOMATION_SETTINGS_SOURCE,
            ],
            sources: &[
                TASK_BOARD_AUTOMATION_STATUS_SOURCE,
                TASK_BOARD_AUTOMATION_SETTINGS_SOURCE,
                TASK_BOARD_AUTOMATION_PROTOCOL_SOURCE,
            ],
        },
        GeneratedModule {
            output: GIT_RUNTIME_OUTPUT,
            description: "the Rust task-board git runtime config and secret-handoff response",
            defaults: &[TASK_BOARD_CREDENTIAL_SOURCE],
            sources: &[TASK_BOARD_CREDENTIAL_SOURCE, TASK_BOARD_PROTOCOL_SOURCE],
        },
        GeneratedModule {
            output: GIT_SIGNING_VERIFY_OUTPUT,
            description: "the Rust task-board git signing verify outcome",
            defaults: &[],
            sources: &[TASK_BOARD_PROTOCOL_SOURCE],
        },
        GeneratedModule {
            output: ACP_EVENT_BATCH_OUTPUT,
            description: "the Rust acp_events broadcast push frame and conversation event",
            defaults: &[],
            sources: &[ACP_EVENT_FRAME_SOURCE, ACP_CONVERSATION_EVENT_SOURCE],
        },
        GeneratedModule {
            output: ACP_INCIDENT_OUTPUT,
            description: "the Rust acp incident and agents-reconciled push payloads",
            defaults: &[],
            sources: &[
                ACP_ACTIVE_SOURCE,
                ACP_INCIDENTS_SOURCE,
                ACP_SANDBOX_PROXY_SOURCE,
            ],
        },
        GeneratedModule {
            output: LOCAL_CLONE_PROGRESS_OUTPUT,
            description: "the Rust reviews local-clone progress push payload",
            defaults: &[],
            sources: &[LOCAL_CLONE_PROGRESS_SOURCE],
        },
    ]
}

/// Generate the Swift wire-type source for one module.
///
/// The driver parses one source at a time, dropping each AST before the next, so
/// only the current file's syntax tree and one descriptor are live at once.
fn generate_module(module: &GeneratedModule) -> String {
    let symbols = build_symbol_table(module.sources);
    let defaults = parse_defaults(module.defaults, &symbols);
    let mut out = format!(
        "// swift-format-ignore-file\n\
         // Generated by examples/policy-codegen.rs from {}\n\
         // Do not edit by hand - rerun: mise run codegen\n\n\
         import Foundation\n",
        module.description
    );
    // Extra Swift module imports for a generated file, so it can reference wire
    // types another module already owns instead of re-emitting them (the dispatch
    // graph reuses HarnessMonitorPolicyModels' PolicyDecision/PolicyReasonCode).
    let extra_imports: &[&str] = match module.output {
        TASK_BOARD_DISPATCH_OUTPUT => &["HarnessMonitorPolicyModels"],
        _ => &[],
    };
    for import in extra_imports {
        writeln!(out, "import {import}").unwrap();
    }
    let emit_only: &[&str] = match module.output {
        SUMMARIES_OUTPUT => SUMMARIES_EMIT_ONLY,
        OBSERVE_OUTPUT => OBSERVE_EMIT_ONLY,
        SESSION_STATE_OUTPUT => SESSION_STATE_EMIT_ONLY,
        POLICY_CANVAS_OUTPUT => POLICY_CANVAS_EMIT_ONLY,
        TASK_BOARD_ENUMS_OUTPUT => TASK_BOARD_ENUMS_EMIT_ONLY,
        TASK_BOARD_SUMMARY_OUTPUT => TASK_BOARD_SUMMARY_EMIT_ONLY,
        TASK_BOARD_ITEM_OUTPUT => TASK_BOARD_ITEM_EMIT_ONLY,
        TASK_BOARD_MACHINES_OUTPUT => TASK_BOARD_MACHINES_EMIT_ONLY,
        TASK_BOARD_PLANNING_OUTPUT => TASK_BOARD_PLANNING_EMIT_ONLY,
        TASK_BOARD_EVALUATION_OUTPUT => TASK_BOARD_EVALUATION_EMIT_ONLY,
        TASK_BOARD_DISPATCH_OUTPUT => TASK_BOARD_DISPATCH_EMIT_ONLY,
        ACP_PROBE_OUTPUT => ACP_PROBE_EMIT_ONLY,
        AGENT_PERSONA_OUTPUT => AGENT_PERSONA_EMIT_ONLY,
        RUNTIME_MODELS_OUTPUT => RUNTIME_MODELS_EMIT_ONLY,
        ACP_DESCRIPTOR_OUTPUT => ACP_DESCRIPTOR_EMIT_ONLY,
        ACP_INSPECT_OUTPUT => ACP_INSPECT_EMIT_ONLY,
        ACP_PERMISSION_OUTPUT => ACP_PERMISSION_EMIT_ONLY,
        ACP_SNAPSHOT_OUTPUT => ACP_SNAPSHOT_EMIT_ONLY,
        ACP_START_REQUEST_OUTPUT => ACP_START_REQUEST_EMIT_ONLY,
        AGENT_TUI_OUTPUT => AGENT_TUI_EMIT_ONLY,
        AGENT_TUI_INPUT_OUTPUT => AGENT_TUI_INPUT_EMIT_ONLY,
        WEBSOCKET_OUTPUT => WEBSOCKET_EMIT_ONLY,
        MANAGED_AGENTS_OUTPUT => MANAGED_AGENTS_EMIT_ONLY,
        DAEMON_STATE_OUTPUT => DAEMON_STATE_EMIT_ONLY,
        SESSION_SIGNAL_OUTPUT => SESSION_SIGNAL_EMIT_ONLY,
        AGENT_REGISTRATION_OUTPUT => AGENT_REGISTRATION_EMIT_ONLY,
        TASK_BOARD_CREDENTIAL_OUTPUT => TASK_BOARD_CREDENTIAL_EMIT_ONLY,
        BRIDGE_STATUS_OUTPUT => BRIDGE_STATUS_EMIT_ONLY,
        SYNC_SUMMARY_OUTPUT => SYNC_SUMMARY_EMIT_ONLY,
        GITHUB_CONFIG_OUTPUT => GITHUB_CONFIG_EMIT_ONLY,
        ORCHESTRATOR_OUTPUT => ORCHESTRATOR_EMIT_ONLY,
        TASK_BOARD_AUTOMATION_OUTPUT => TASK_BOARD_AUTOMATION_EMIT_ONLY,
        GIT_RUNTIME_OUTPUT => GIT_RUNTIME_EMIT_ONLY,
        GIT_SIGNING_VERIFY_OUTPUT => GIT_SIGNING_VERIFY_EMIT_ONLY,
        ACP_EVENT_BATCH_OUTPUT => ACP_EVENT_BATCH_EMIT_ONLY,
        ACP_INCIDENT_OUTPUT => ACP_INCIDENT_EMIT_ONLY,
        LOCAL_CLONE_PROGRESS_OUTPUT => LOCAL_CLONE_PROGRESS_EMIT_ONLY,
        _ => &[],
    };
    for source in module.sources {
        emit_source_decls(&mut out, source, &defaults, &symbols, emit_only);
    }
    out
}

/// Generate the policy-graph module. Retained for the emitter unit tests.
#[cfg(test)]
fn generate_policy_swift() -> String {
    generate_module(&modules()[0])
}

fn repository_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("policy-codegen manifest must live under tools/policy-codegen")
}

fn main() {
    let check = std::env::args().any(|arg| arg == "--check");
    let root = repository_root();
    let rendered: Vec<(GeneratedModule, String)> = modules()
        .into_iter()
        .map(|module| {
            let generated = generate_module(&module);
            (module, generated)
        })
        .collect();
    // Types resolve across modules, so the whole set has to exist before any
    // one of them can be checked for a name nothing defines.
    let declared: BTreeSet<String> = rendered
        .iter()
        .flat_map(|(_, generated)| swift_type_check::declared_types(generated))
        .collect();
    let mut undefined: Vec<(&str, BTreeSet<String>)> = Vec::new();
    let mut drifted: Vec<&str> = Vec::new();
    for (module, generated) in &rendered {
        let missing = swift_type_check::undefined_types(generated, &declared);
        if !missing.is_empty() {
            undefined.push((module.output, missing));
        }
        let path = root.join(module.output);
        if check {
            let committed = fs::read_to_string(&path).unwrap_or_default();
            if committed != *generated {
                drifted.push(module.output);
            }
        } else {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("create generated module directory");
            }
            fs::write(&path, generated).expect("write generated Swift module");
        }
    }
    if !undefined.is_empty() {
        for (output, missing) in &undefined {
            for name in missing {
                eprintln!(
                    "undefined type: {output} references `{name}`, which no generated module \
                     defines - add its Rust source to that module's `sources` (and the name to \
                     its emit list), or declare it in EXTERNAL_SWIFT_TYPES if Swift owns it"
                );
            }
        }
        std::process::exit(1);
    }
    if check && !drifted.is_empty() {
        for output in &drifted {
            eprintln!("drift: {output} is stale - run `mise run codegen`");
        }
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_root_resolves_workspace() {
        let root = repository_root();
        assert!(root.join("Cargo.toml").is_file());
        assert!(root.join("apps/harness-monitor").is_dir());
    }

    fn string_enum_case(name: &str, raw_value: &str) -> SwiftStringEnumCase {
        SwiftStringEnumCase {
            name: name.to_string(),
            raw_value: raw_value.to_string(),
            aliases: Vec::new(),
        }
    }

    #[test]
    fn emits_string_backed_enum_with_snake_case_raw_values() {
        let spec = SwiftStringEnum {
            name: "PolicyGraphMode".to_string(),
            cases: vec![
                string_enum_case("draft", "draft"),
                string_enum_case("dryRun", "dry_run"),
                string_enum_case("enforced", "enforced"),
            ],
        };

        let expected = "public enum PolicyGraphMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {\n  case draft = \"draft\"\n  case dryRun = \"dry_run\"\n  case enforced = \"enforced\"\n\n  public var id: String { rawValue }\n}\n";
        let mut out = String::new();
        emit_string_enum(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn emits_open_enum_with_unknown_fallback() {
        let spec = SwiftStringEnum {
            name: "TaskBoardGitSigningMode".to_string(),
            cases: vec![
                string_enum_case("none", "none"),
                string_enum_case("ssh", "ssh"),
                string_enum_case("gpg", "gpg"),
            ],
        };

        let expected = r#"public enum TaskBoardGitSigningMode: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case none
  case ssh
  case gpg
  case unknown(String)

  public static let allCases: [Self] = [.none, .ssh, .gpg]

  public var rawValue: String {
    switch self {
    case .none: "none"
    case .ssh: "ssh"
    case .gpg: "gpg"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .none
    case "ssh": self = .ssh
    case "gpg": self = .gpg
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }
}
"#;
        let mut out = String::new();
        emit_open_enum(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn open_enum_drops_explicit_unknown_variant() {
        let spec = SwiftStringEnum {
            name: "ReviewMergeableState".to_string(),
            cases: vec![
                string_enum_case("mergeable", "mergeable"),
                string_enum_case("conflicting", "conflicting"),
                string_enum_case("unknown", "unknown"),
            ],
        };

        let expected = r#"public enum ReviewMergeableState: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case mergeable
  case conflicting
  case unknown(String)

  public static let allCases: [Self] = [.mergeable, .conflicting]

  public var rawValue: String {
    switch self {
    case .mergeable: "mergeable"
    case .conflicting: "conflicting"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "mergeable": self = .mergeable
    case "conflicting": self = .conflicting
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }
}
"#;
        let mut out = String::new();
        emit_open_enum(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn emits_string_newtype_wrapper() {
        let expected = "\
public struct SampleId: RawRepresentable, Codable, Hashable, Sendable, Comparable, \
ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
  public init(stringLiteral value: String) {
    self.rawValue = value
  }
  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
  public var description: String {
    rawValue
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
";
        let mut out = String::new();
        emit_newtype(&mut out, "SampleId");
        assert_eq!(out, expected);
    }

    #[test]
    fn emit_only_restricts_to_allow_listed_types() {
        let source = "\
#[derive(Serialize, Deserialize)]
pub struct Keep { pub value: String }
#[derive(Serialize, Deserialize)]
pub struct Drop { pub other: String }
";
        let symbols = build_symbol_table(&[source]);
        let defaults = parse_defaults(&[], &symbols);

        let mut restricted = String::new();
        emit_source_decls(&mut restricted, source, &defaults, &symbols, &["Keep"]);
        assert!(restricted.contains("struct Keep"));
        assert!(!restricted.contains("struct Drop"));

        // An empty allow-list keeps the default "emit every non-skipped type"
        // behavior, so existing modules stay byte-identical.
        let mut all = String::new();
        emit_source_decls(&mut all, source, &defaults, &symbols, &[]);
        assert!(all.contains("struct Keep"));
        assert!(all.contains("struct Drop"));
    }

    #[test]
    fn pascal_to_camel_lowercases_first_letter() {
        assert_eq!(pascal_to_camel("DryRun"), "dryRun");
        assert_eq!(pascal_to_camel("OcrImage"), "ocrImage");
        assert_eq!(pascal_to_camel("Hub"), "hub");
    }

    #[test]
    fn variant_wire_value_respects_rename_all() {
        assert_eq!(
            variant_wire_value("SpeechToText", Some("camelCase")),
            "speechToText"
        );
        assert_eq!(
            variant_wire_value("SpeechToText", Some("snake_case")),
            "speech_to_text"
        );
        assert_eq!(variant_wire_value("SpeechToText", None), "speech_to_text");
        assert_eq!(variant_wire_value("Live", Some("camelCase")), "live");
    }

    #[test]
    fn builds_camel_case_string_enum_from_rename_all() {
        let item: ItemEnum = syn::parse_str(
            "#[serde(rename_all = \"camelCase\")] enum VoiceSink { SpeechToText, Raw }",
        )
        .expect("enum parses");
        let spec = build_string_enum(&item);
        assert_eq!(
            spec.cases,
            vec![
                string_enum_case("speechToText", "speechToText"),
                string_enum_case("raw", "raw"),
            ]
        );
    }

    #[test]
    fn variant_rename_is_canonical_and_alias_is_decode_only() {
        let item: ItemEnum = syn::parse_str(
            "#[serde(rename_all = \"snake_case\")] enum Provider { #[serde(rename = \"github\", alias = \"git_hub\")] GitHub, Todoist }",
        )
        .expect("enum parses");
        let spec = build_string_enum(&item);
        assert_eq!(
            spec.cases,
            vec![
                SwiftStringEnumCase {
                    name: "gitHub".to_string(),
                    raw_value: "github".to_string(),
                    aliases: vec!["git_hub".to_string()],
                },
                string_enum_case("todoist", "todoist"),
            ]
        );

        let mut out = String::new();
        emit_string_enum(&mut out, &spec);
        assert!(out.contains("case gitHub = \"github\""));
        assert!(out.contains("case \"github\", \"git_hub\": self = .gitHub"));
        assert!(out.contains("try container.encode(rawValue)"));
    }

    #[test]
    fn pascal_to_snake_matches_serde_rename_all() {
        assert_eq!(pascal_to_snake("DryRun"), "dry_run");
        assert_eq!(
            pascal_to_snake("ReviewScreenshotPaste"),
            "review_screenshot_paste"
        );
        assert_eq!(pascal_to_snake("OcrImage"), "ocr_image");
    }

    #[test]
    fn snake_to_camel_uppercases_after_underscores() {
        assert_eq!(snake_to_camel("input_ports"), "inputPorts");
        assert_eq!(snake_to_camel("group_id"), "groupId");
        assert_eq!(snake_to_camel("id"), "id");
    }

    fn swift_type_string(rust_type: &str) -> String {
        let ty: Type = syn::parse_str(rust_type).expect("valid Rust type");
        let mapped = rust_type_to_swift(&ty);
        if mapped.optional {
            format!("{}?", mapped.name)
        } else {
            mapped.name
        }
    }

    #[test]
    fn maps_scalars_to_exact_width_swift_types() {
        assert_eq!(swift_type_string("u8"), "UInt8");
        assert_eq!(swift_type_string("u16"), "UInt16");
        assert_eq!(swift_type_string("u32"), "UInt32");
        assert_eq!(swift_type_string("u64"), "UInt64");
        assert_eq!(swift_type_string("i32"), "Int32");
        assert_eq!(swift_type_string("f64"), "Double");
        assert_eq!(swift_type_string("bool"), "Bool");
        assert_eq!(swift_type_string("String"), "String");
    }

    #[test]
    fn maps_option_and_vec_containers() {
        assert_eq!(swift_type_string("Option<String>"), "String?");
        assert_eq!(swift_type_string("Vec<String>"), "[String]");
        assert_eq!(swift_type_string("Vec<PolicyAction>"), "[PolicyAction]");
        assert_eq!(
            swift_type_string("Option<PolicyGraphAutomationBinding>"),
            "PolicyGraphAutomationBinding?"
        );
    }

    #[test]
    fn maps_serde_json_value_to_json_value() {
        assert_eq!(swift_type_string("serde_json::Value"), "JSONValue");
        assert_eq!(swift_type_string("Value"), "JSONValue");
        assert_eq!(swift_type_string("JsonValue"), "JSONValue");
        assert_eq!(swift_type_string("Option<serde_json::Value>"), "JSONValue?");
        assert_eq!(swift_type_string("Vec<serde_json::Value>"), "[JSONValue]");
    }

    #[test]
    fn maps_chrono_datetime_to_string() {
        assert_eq!(swift_type_string("DateTime<Utc>"), "String");
        assert_eq!(swift_type_string("Option<DateTime<Utc>>"), "String?");
        assert_eq!(swift_type_string("Vec<DateTime<Utc>>"), "[String]");
    }

    #[test]
    fn maps_pathbuf_to_string() {
        assert_eq!(swift_type_string("PathBuf"), "String");
        assert_eq!(swift_type_string("Option<PathBuf>"), "String?");
        assert_eq!(swift_type_string("Vec<PathBuf>"), "[String]");
    }

    #[test]
    fn maps_hash_and_btree_maps_to_dictionaries() {
        assert_eq!(
            swift_type_string("BTreeMap<String, usize>"),
            "[String: UInt]"
        );
        assert_eq!(
            swift_type_string("HashMap<String, String>"),
            "[String: String]"
        );
        assert_eq!(
            swift_type_string("BTreeMap<String, Vec<PolicyAction>>"),
            "[String: [PolicyAction]]"
        );
        assert_eq!(
            swift_type_string("HashMap<String, Option<String>>"),
            "[String: String?]"
        );
    }

    #[test]
    fn empty_collection_literal_distinguishes_dict_from_array() {
        assert_eq!(empty_collection_literal("[String]"), "[]");
        assert_eq!(empty_collection_literal("[[String]]"), "[]");
        assert_eq!(empty_collection_literal("[String: UInt]"), "[:]");
        assert_eq!(
            empty_collection_literal("[String: [ReviewRepositoryLabelWire]]"),
            "[:]"
        );
        assert_eq!(empty_collection_literal("[[String: UInt]]"), "[]");
    }

    #[test]
    fn unwraps_box_to_the_inner_type() {
        // Use sample names absent from WIRE_SUFFIXED_TYPES so the Box unwrap is
        // tested in isolation from the suffix logic.
        assert_eq!(swift_type_string("Box<BoxedSample>"), "BoxedSample");
        assert_eq!(swift_type_string("Box<String>"), "String");
        assert_eq!(
            swift_type_string("Option<Box<BoxedSample>>"),
            "BoxedSample?"
        );
        assert_eq!(swift_type_string("Vec<Box<BoxedSample>>"), "[BoxedSample]");
    }

    #[test]
    fn flattens_nested_struct_fields_into_parent() {
        let source = r#"
            #[derive(Serialize, Deserialize)]
            pub struct Flags {
                pub starred: bool,
                #[serde(rename = "is_draft")]
                pub draft: bool,
            }
            #[derive(Serialize, Deserialize)]
            pub struct Parent {
                pub id: String,
                #[serde(flatten)]
                pub flags: Flags,
                pub trailing: u32,
            }
        "#;
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let parent = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "Parent" => Some(item.clone()),
                _ => None,
            })
            .expect("Parent struct present");
        let spec = build_struct(&parent, &defaults, &symbols).expect("struct builds");

        let properties: Vec<_> = spec
            .fields
            .iter()
            .map(|field| field.property.as_str())
            .collect();
        assert_eq!(properties, vec!["id", "starred", "draft", "trailing"]);
        let coding_keys: Vec<_> = spec
            .fields
            .iter()
            .map(|field| field.coding_key.as_str())
            .collect();
        assert_eq!(coding_keys, vec!["id", "starred", "is_draft", "trailing"]);
    }

    #[test]
    fn app_optional_skip_default_field_decodes_without_coalesce() {
        // TaskBoardItem.workflow is in SKIP_DEFAULT_OPTIONAL_FIELDS: the daemon
        // omits it when default (`skip_serializing_if = "*::is_default"`) and the
        // app models the absence as nil, so the wire field must be optional with a
        // bare decodeIfPresent. A sibling Vec skip-empty field proves the rule does
        // not over-reach to the ordinary defaulted collections.
        let source = r#"
            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardItem {
                pub id: String,
                #[serde(default, skip_serializing_if = "Vec::is_empty")]
                pub tags: Vec<String>,
                #[serde(default, skip_serializing_if = "TaskBoardWorkflowState::is_default")]
                pub workflow: TaskBoardWorkflowState,
            }
        "#;
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let item = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "TaskBoardItem" => Some(item.clone()),
                _ => None,
            })
            .expect("TaskBoardItem struct present");
        let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");

        let workflow = spec
            .fields
            .iter()
            .find(|field| field.property == "workflow")
            .expect("workflow field present");
        assert!(workflow.optional, "workflow is app-optional");
        assert_eq!(workflow.decode_default, None, "no `?? Default()` coalesce");
        assert_eq!(workflow.init_default.as_deref(), Some("nil"));

        let tags = spec
            .fields
            .iter()
            .find(|field| field.property == "tags")
            .expect("tags field present");
        assert!(!tags.optional, "tags keeps its empty-array default");
        assert_eq!(tags.decode_default.as_deref(), Some("[]"));
    }

    #[test]
    fn hand_model_defaults_keep_listed_automation_settings_optional() {
        let source = r#"
            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardOrchestratorSettings {
                #[serde(default)]
                pub scheduling: TaskBoardAutomationSchedulingSettings,
                #[serde(default)]
                pub retry: TaskBoardAutomationRetrySettings,
                #[serde(default)]
                pub reviewers: TaskBoardReviewerSettings,
                pub policy_version: String,
            }
        "#;
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let item = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "TaskBoardOrchestratorSettings" => {
                    Some(item.clone())
                }
                _ => None,
            })
            .expect("orchestrator settings present");
        let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");

        for property in ["scheduling", "retry", "reviewers"] {
            let field = spec
                .fields
                .iter()
                .find(|field| field.property == property)
                .expect("hand-model-default field present");
            assert!(field.optional, "{property} reaches the hand model as nil");
            assert_eq!(field.decode_default, None, "no duplicated default literal");
            assert_eq!(field.init_default.as_deref(), Some("nil"));
        }

        let policy_version = spec
            .fields
            .iter()
            .find(|field| field.property == "policyVersion")
            .expect("strict field present");
        assert!(!policy_version.optional, "unrelated required fields stay strict");
        assert_eq!(policy_version.decode_default, None);
    }

    #[test]
    fn omitted_wire_field_is_dropped_from_struct() {
        // DispatchPlan.lifecycle is in OMITTED_WIRE_FIELDS: the app does not read it,
        // so the wire type drops the field and the daemon's key is ignored on decode.
        let source = r"
            #[derive(Serialize, Deserialize)]
            pub struct DispatchPlan {
                pub board_item_id: String,
                pub lifecycle: DispatchLifecycle,
            }
        ";
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let item = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "DispatchPlan" => Some(item.clone()),
                _ => None,
            })
            .expect("DispatchPlan struct present");
        let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");
        let properties: Vec<_> = spec
            .fields
            .iter()
            .map(|field| field.property.as_str())
            .collect();
        assert_eq!(properties, vec!["boardItemId"], "lifecycle is dropped");
    }

    #[test]
    fn automation_snapshot_is_emitted_in_monitor_status_wire() {
        let source = r"
            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardOrchestratorStatus {
                pub enabled: bool,
                pub automation: TaskBoardAutomationSnapshot,
            }
        ";
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let item = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "TaskBoardOrchestratorStatus" => {
                    Some(item.clone())
                }
                _ => None,
            })
            .expect("TaskBoardOrchestratorStatus struct present");
        let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");
        let properties: Vec<_> = spec
            .fields
            .iter()
            .map(|field| field.property.as_str())
            .collect();

        assert_eq!(properties, vec!["enabled", "automation"]);
    }

    #[test]
    fn admission_policy_is_deferred_from_monitor_settings_wire() {
        let source = r"
            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardOrchestratorSettings {
                pub dry_run_default: bool,
                pub admission_policy: TaskBoardAutomationPolicy,
            }
        ";
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        let item = file
            .items
            .iter()
            .find_map(|item| match item {
                Item::Struct(item) if item.ident == "TaskBoardOrchestratorSettings" => {
                    Some(item.clone())
                }
                _ => None,
            })
            .expect("TaskBoardOrchestratorSettings present");
        let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");
        let properties: Vec<_> = spec
            .fields
            .iter()
            .map(|field| field.property.as_str())
            .collect();

        assert_eq!(properties, vec!["dryRunDefault"]);
    }

    #[test]
    fn local_execution_host_is_deferred_from_monitor_settings_wires() {
        let source = r"
            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardOrchestratorSettings {
                pub dry_run_default: bool,
                pub local_execution_host: TaskBoardLocalExecutionHostConfig,
            }

            #[derive(Serialize, Deserialize)]
            pub struct TaskBoardOrchestratorSettingsUpdateRequest {
                pub dry_run_default: Option<bool>,
                pub local_execution_host: Option<TaskBoardLocalExecutionHostConfig>,
            }
        ";
        let symbols = build_symbol_table(&[source]);
        let defaults = DefaultLiterals::new();
        let file = syn::parse_file(source).expect("source parses");
        for struct_name in [
            "TaskBoardOrchestratorSettings",
            "TaskBoardOrchestratorSettingsUpdateRequest",
        ] {
            let item = file
                .items
                .iter()
                .find_map(|item| match item {
                    Item::Struct(item) if item.ident == struct_name => Some(item.clone()),
                    _ => None,
                })
                .expect("orchestrator settings struct present");
            let spec = build_struct(&item, &defaults, &symbols).expect("struct builds");
            let properties: Vec<_> = spec
                .fields
                .iter()
                .map(|field| field.property.as_str())
                .collect();
            assert_eq!(properties, vec!["dryRunDefault"]);
        }
    }

    #[test]
    fn suffixes_only_listed_wire_types() {
        assert_eq!(
            swift_type_name("HarnessMonitorAuditEvent", &["HarnessMonitorAuditEvent"]),
            "HarnessMonitorAuditEventWire"
        );
        assert_eq!(
            swift_type_name("PolicyGraphNode", &["HarnessMonitorAuditEvent"]),
            "PolicyGraphNode"
        );
        assert_eq!(swift_type_name("Foo", &[]), "Foo");
    }

    #[test]
    fn renames_take_precedence_over_suffix() {
        assert_eq!(
            swift_type_name("HarnessCodeLanguage", &["HarnessCodeLanguage"]),
            "HarnessReviewFileLanguage"
        );
        assert_eq!(
            swift_type_name("HarnessCodeLanguage", &[]),
            "HarnessReviewFileLanguage"
        );
    }

    #[test]
    fn maps_named_types_unchanged() {
        assert_eq!(
            swift_type_string("PolicyEvidenceField"),
            "PolicyEvidenceField"
        );
    }

    #[test]
    fn emits_struct_with_init_decoder_and_coding_keys() {
        let spec = SwiftStruct {
            name: "Sample".to_string(),
            fields: vec![
                SwiftField {
                    property: "id".to_string(),
                    coding_key: "id".to_string(),
                    type_name: "String".to_string(),
                    optional: false,
                    decode_default: None,
                    init_default: None,
                },
                SwiftField {
                    property: "groupId".to_string(),
                    coding_key: "group_id".to_string(),
                    type_name: "String".to_string(),
                    optional: true,
                    decode_default: None,
                    init_default: Some("nil".to_string()),
                },
                SwiftField {
                    property: "inputPorts".to_string(),
                    coding_key: "input_ports".to_string(),
                    type_name: "[String]".to_string(),
                    optional: false,
                    decode_default: Some("[]".to_string()),
                    init_default: Some("[]".to_string()),
                },
            ],
        };

        let expected = "\
public struct Sample: Codable, Equatable, Sendable {
  public var id: String
  public var groupId: String?
  public var inputPorts: [String]

  public init(id: String, groupId: String? = nil, inputPorts: [String] = []) {
    self.id = id
    self.groupId = groupId
    self.inputPorts = inputPorts
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
    inputPorts = try container.decodeIfPresent([String].self, forKey: .inputPorts) ?? []
  }

  enum CodingKeys: String, CodingKey {
    case id
    case groupId = \"group_id\"
    case inputPorts = \"input_ports\"
  }
}
";
        let mut out = String::new();
        emit_struct(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn emits_empty_struct_without_empty_coding_keys() {
        let spec = SwiftStruct {
            name: "EmptyRequest".to_string(),
            fields: Vec::new(),
        };

        let expected = "\
public struct EmptyRequest: Codable, Equatable, Sendable {

  public init() {
  }
}\n";
        let mut out = String::new();
        emit_struct(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn emits_internally_tagged_enum_with_all_variant_shapes() {
        let spec = SwiftTaggedEnum {
            name: "Sample".to_string(),
            tag: "kind".to_string(),
            content: None,
            variants: vec![
                SwiftTaggedVariant {
                    case_name: "hub".to_string(),
                    raw_tag: "hub".to_string(),
                    payload: VariantPayload::Unit,
                },
                SwiftTaggedVariant {
                    case_name: "timer".to_string(),
                    raw_tag: "timer".to_string(),
                    payload: VariantPayload::Fields(vec![SwiftField {
                        property: "durationSeconds".to_string(),
                        coding_key: "duration_seconds".to_string(),
                        type_name: "UInt64".to_string(),
                        optional: false,
                        decode_default: None,
                        init_default: None,
                    }]),
                },
                SwiftTaggedVariant {
                    case_name: "entry".to_string(),
                    raw_tag: "entry".to_string(),
                    payload: VariantPayload::Newtype("PolicyWorkflowEntry".to_string()),
                },
            ],
        };

        let expected = "\
public enum Sample: Codable, Equatable, Sendable {
  case hub
  case timer(durationSeconds: UInt64)
  case entry(PolicyWorkflowEntry)

  enum CodingKeys: String, CodingKey {
    case kind
    case durationSeconds = \"duration_seconds\"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case \"hub\":
      self = .hub
    case \"timer\":
      self = .timer(durationSeconds: try container.decode(UInt64.self, forKey: .durationSeconds))
    case \"entry\":
      self = .entry(try PolicyWorkflowEntry(from: decoder))
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: \"unknown Sample kind \\(kind)\")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hub:
      try container.encode(\"hub\", forKey: .kind)
    case .timer(let durationSeconds):
      try container.encode(\"timer\", forKey: .kind)
      try container.encode(durationSeconds, forKey: .durationSeconds)
    case .entry(let value):
      try container.encode(\"entry\", forKey: .kind)
      try value.encode(to: encoder)
    }
  }
}
";
        let mut out = String::new();
        emit_tagged_enum(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn emits_adjacently_tagged_enum_nesting_payload_under_content_key() {
        let spec = SwiftTaggedEnum {
            name: "ManagedAgentSnapshotWire".to_string(),
            tag: "kind".to_string(),
            content: Some("snapshot".to_string()),
            variants: vec![
                SwiftTaggedVariant {
                    case_name: "terminal".to_string(),
                    raw_tag: "terminal".to_string(),
                    payload: VariantPayload::Newtype("AgentTuiSnapshotWire".to_string()),
                },
                SwiftTaggedVariant {
                    case_name: "codex".to_string(),
                    raw_tag: "codex".to_string(),
                    payload: VariantPayload::Newtype("CodexRunSnapshotWire".to_string()),
                },
            ],
        };

        let expected = "\
public enum ManagedAgentSnapshotWire: Codable, Equatable, Sendable {
  case terminal(AgentTuiSnapshotWire)
  case codex(CodexRunSnapshotWire)

  enum CodingKeys: String, CodingKey {
    case kind
    case snapshot
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case \"terminal\":
      self = .terminal(try container.decode(AgentTuiSnapshotWire.self, forKey: .snapshot))
    case \"codex\":
      self = .codex(try container.decode(CodexRunSnapshotWire.self, forKey: .snapshot))
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: \"unknown ManagedAgentSnapshotWire kind \\(kind)\")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .terminal(let value):
      try container.encode(\"terminal\", forKey: .kind)
      try container.encode(value, forKey: .snapshot)
    case .codex(let value):
      try container.encode(\"codex\", forKey: .kind)
      try container.encode(value, forKey: .snapshot)
    }
  }
}
";
        let mut out = String::new();
        emit_tagged_enum(&mut out, &spec);
        assert_eq!(out, expected);
    }

    #[test]
    fn resolves_enum_variant_and_const_default_fns() {
        let source = "\
const DEFAULT_ROWS: u16 = 30;
fn default_role() -> SessionRole { SessionRole::Worker }
fn default_rows() -> u16 { DEFAULT_ROWS }
fn default_label() -> String { \"draft\".to_string() }
";
        let symbols = build_symbol_table(&[source]);
        let defaults = parse_defaults(&[source], &symbols);

        // Enum-variant body -> the Swift enum case.
        assert_eq!(defaults.get("default_role"), Some(&".worker".to_string()));
        // Named-constant body -> the constant's collected literal.
        assert_eq!(defaults.get("default_rows"), Some(&"30".to_string()));
        // Plain literal bodies keep resolving as before.
        assert_eq!(
            defaults.get("default_label"),
            Some(&"\"draft\"".to_string())
        );
    }

    #[test]
    fn generates_swift_for_real_policy_sources() {
        let swift = generate_policy_swift();

        assert!(swift.starts_with("// swift-format-ignore-file\n"));
        assert!(swift.contains("// Generated by examples/policy-codegen.rs"));
        assert!(swift.contains("\nimport Foundation\n"));

        // String-backed enum with snake_case raw values.
        assert!(swift.contains(
            "public enum PolicyGraphMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {"
        ));
        assert!(swift.contains("case dryRun = \"dry_run\""));
        assert!(swift.contains("public var id: String { rawValue }"));

        // All-unit internally-tagged enum gains synthesized CaseIterable + Hashable
        // for pickers.
        assert!(swift.contains(
            "public enum PolicyEvidencePredicate: Codable, Equatable, Hashable, Sendable, CaseIterable {"
        ));

        // Internally-tagged enum: every variant shape, exact-width ints, camelCase.
        assert!(swift.contains("public enum PolicyGraphNodeKind: Codable, Equatable, Sendable {"));
        assert!(swift.contains("case hub\n"));
        assert!(swift.contains("case workflowEntry(PolicyWorkflowEntry)"));
        assert!(swift.contains(
            "case riskClassifier(field: PolicyEvidenceField, threshold: UInt8, \
             highRiskReasonCode: PolicyReasonCode, missingReasonCode: PolicyReasonCode)"
        ));
        assert!(swift.contains("case ocrImage\n"));
        assert!(swift.contains("case \"risk_classifier\":"));

        // Struct field coding keys map camelCase property to snake_case wire key.
        assert!(swift.contains("case fromNode = \"from_node\""));

        // Serde-transparent id newtypes emit as RawRepresentable String wrappers,
        // and the graph structs adopt them in place of bare String ids.
        assert!(swift.contains(
            "public struct PolicyGraphNodeId: RawRepresentable, Codable, Hashable, Sendable, \
             Comparable, ExpressibleByStringLiteral, CustomStringConvertible {"
        ));
        assert!(swift.contains("  public var id: PolicyGraphNodeId\n"));
        assert!(swift.contains("  public var fromNode: PolicyGraphNodeId\n"));
        assert!(swift.contains("  public var inputPorts: [PolicyGraphPortId]\n"));

        // Defaults resolved from defaults.rs: skipped zoom and always-present strings.
        assert!(swift.contains("?? 1.0"));
        assert!(swift.contains("?? \"allExceptDenied\""));

        // Bare #[serde(default)] on an enum field resolves to its #[default] variant.
        assert!(swift.contains("?? .always"));

        // Bare #[serde(default)] on a Default-deriving struct field resolves to a zero-arg init.
        assert!(swift.contains("?? PolicyCanvasPoint()"));
        assert!(swift.contains("public init(x: Int32 = 0, y: Int32 = 0)"));

        // Swift reserved words are backtick-escaped where used as identifiers.
        assert!(swift.contains("case `switch`(PolicySwitchNode)"));
        assert!(swift.contains("self = .`switch`(try PolicySwitchNode(from: decoder))"));

        // Every type resolved - no AnyCodable fallback leaked into the output.
        assert!(!swift.contains("AnyCodable"));
    }
}

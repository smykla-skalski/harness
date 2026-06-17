//! Rust -> Swift wire-type generator for the policy-canvas pilot.
//!
//! Reads the policy-graph Rust types and emits Codable Swift that round-trips
//! the serde wire format. Built in-house: specta-swift 0.0.3 stack-overflows on
//! internally-tagged enums and typeshare cannot express the adjacently-tagged
//! enums later increments need. Run with:
//! `mise run cargo:local -- run --example policy-codegen`.
//!
//! Memory discipline: every emitter appends into one caller-owned `String`
//! buffer via `write!` (no per-item temporaries), the case helpers pre-size
//! their single allocation, and the driver streams one source file at a time so
//! only the current file's AST and one type live at once.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use syn::{
    Attribute, Expr, Fields, FieldsNamed, GenericArgument, Item, ItemEnum, ItemStruct, Lit,
    PathArguments, Stmt, Type, Variant,
};

/// A Swift `String`-backed enum generated from a fieldless, `rename_all =
/// "snake_case"` Rust enum. Each case pairs the Swift case name with its serde
/// raw value.
struct SwiftStringEnum {
    name: String,
    cases: Vec<(String, String)>,
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
    for (case, raw) in &spec.cases {
        writeln!(out, "  case {case} = \"{raw}\"").unwrap();
    }
    out.push_str("\n  public var id: String { rawValue }\n");
    out.push_str("}\n");
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
    let cases: Vec<&(String, String)> =
        spec.cases.iter().filter(|(case, _)| case != "unknown").collect();
    writeln!(
        out,
        "public enum {}: TaskBoardOpenEnum, CaseIterable, Identifiable {{",
        spec.name
    )
    .unwrap();
    for (case, _) in &cases {
        writeln!(out, "  case {case}").unwrap();
    }
    out.push_str("  case unknown(String)\n\n");
    let known = cases
        .iter()
        .map(|(case, _)| format!(".{case}"))
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(out, "  public static let allCases: [Self] = [{known}]\n").unwrap();
    out.push_str("  public var rawValue: String {\n    switch self {\n");
    for (case, raw) in &cases {
        writeln!(out, "    case .{case}: \"{raw}\"").unwrap();
    }
    out.push_str("    case .unknown(let raw): raw\n    }\n  }\n\n");
    out.push_str("  public init(rawValue: String) {\n    switch rawValue {\n");
    for (case, raw) in &cases {
        writeln!(out, "    case \"{raw}\": self = .{case}").unwrap();
    }
    out.push_str("    default: self = .unknown(rawValue)\n    }\n  }\n\n");
    out.push_str("  public var id: String { rawValue }\n");
    out.push_str("}\n");
}

/// Emit a Codable Swift struct with a memberwise initializer, a decoder that
/// applies wire defaults, and `CodingKeys` mapping camelCase to snake_case wire
/// names. Everything appends into `out`.
fn emit_struct(out: &mut String, spec: &SwiftStruct) {
    writeln!(out, "public struct {}: Codable, Equatable, Sendable {{", spec.name).unwrap();
    for field in &spec.fields {
        out.push_str("  public var ");
        out.push_str(&field.property);
        out.push_str(": ");
        push_type(out, field);
        out.push('\n');
    }

    out.push('\n');
    emit_memberwise_init(out, spec);

    if spec.fields.iter().any(|field| field.decode_default.is_some()) {
        out.push('\n');
        emit_decoder(out, spec);
    }

    out.push('\n');
    emit_coding_keys(out, spec);
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
    decode_default: &Option<String>,
    type_name: &str,
    rust_ident: Option<&str>,
    derives_default: bool,
    symbols: &SymbolTable,
) -> Option<String> {
    if optional {
        return Some("nil".to_string());
    }
    if let Some(default) = decode_default {
        return Some(default.clone());
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
            writeln!(out, "    case {} = \"{}\"", field.property, field.coding_key).unwrap();
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
                writeln!(out, "    case {} = \"{}\"", field.property, field.coding_key).unwrap();
            }
        }
    }
    out.push_str("  }\n");
}

fn emit_tagged_decoder(out: &mut String, spec: &SwiftTaggedEnum) {
    out.push_str("  public init(from decoder: Decoder) throws {\n");
    out.push_str("    let container = try decoder.container(keyedBy: CodingKeys.self)\n");
    writeln!(out, "    let {0} = try container.decode(String.self, forKey: .{0})", spec.tag).unwrap();
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
        write!(out, "try container.decodeIfPresent({}.self, forKey: .{})", field.type_name, field.property).unwrap();
    } else if let Some(default) = &field.decode_default {
        write!(out, "try container.decodeIfPresent({}.self, forKey: .{}) ?? {}", field.type_name, field.property, default).unwrap();
    } else {
        write!(out, "try container.decode({}.self, forKey: .{})", field.type_name, field.property).unwrap();
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
            writeln!(out, "      try container.encode(\"{}\", forKey: .{})", variant.raw_tag, tag).unwrap();
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
            writeln!(out, "      try container.encode(\"{}\", forKey: .{})", variant.raw_tag, tag).unwrap();
            for field in fields {
                writeln!(out, "      try container.encode({0}, forKey: .{0})", field.property).unwrap();
            }
        }
        VariantPayload::Newtype(_inner) => {
            writeln!(out, "    case .{}(let value):", variant.case_name).unwrap();
            writeln!(out, "      try container.encode(\"{}\", forKey: .{})", variant.raw_tag, tag).unwrap();
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
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
    "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
    "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
    "switch", "where", "while", "as", "catch", "false", "is", "nil", "super", "self", "Self",
    "throw", "throws", "true", "try", "Any", "_",
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
        return SwiftType { name: "AnyCodable".to_string(), optional: false };
    };
    let Some(segment) = type_path.path.segments.last() else {
        return SwiftType { name: "AnyCodable".to_string(), optional: false };
    };
    let ident = segment.ident.to_string();
    match ident.as_str() {
        "Option" => SwiftType {
            name: first_generic_arg(&segment.arguments)
                .map(rust_type_to_swift)
                .map_or_else(|| "AnyCodable".to_string(), |mapped| mapped.name),
            optional: true,
        },
        "Vec" => SwiftType {
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
        "Box" => first_generic_arg(&segment.arguments)
            .map(rust_type_to_swift)
            .unwrap_or_else(|| SwiftType { name: "AnyCodable".to_string(), optional: false }),
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
    // (TaskBoardPolicyPipelineSimulationResult/...AuditSummary) keep their flat
    // shape; these *Wire types own the daemon snake_case decode (the validation
    // report nests the generated PolicyGraphValidationIssue, which fixes the
    // node_id/edge_id/node_ids drop when simulate/audit decoded via convertFromSnakeCase).
    "PolicyPipelineSimulatedDecision",
    "PolicyPipelineSimulationResult",
    "PolicyPipelineAuditSummary",
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
    // websocket config/probe/inspect payloads: reference unmigrated persona,
    // runtime-catalog and acp types (AgentPersona / RuntimeModelCatalog /
    // AcpAgentDescriptor / AcpRuntimeProbeResponse / AcpAgentInspectResponse).
    // Generate them with those subsystems, not the transport envelope.
    "WsConfigPayload",
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
    // save/promote responses already decode via the plain policy-wire decoder and
    // GraphPolicyGate is daemon-internal. Adding store.rs as a policy-module source
    // for the cluster wire types must not also emit these (bare names that would
    // clash / produce dead types).
    "GraphPolicyGate",
    "PolicyPipelineSaveResponse",
    "PolicyPipelinePromoteRequest",
    "PolicyPipelinePromoteResponse",
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
    // reviews ReviewFile.language_hint: Rust HarnessCodeLanguage is the Swift
    // hand enum HarnessReviewFileLanguage.
    ("HarnessCodeLanguage", "HarnessReviewFileLanguage"),
    // reviews types.rs request methods: Rust GitHubMergeMethod (task_board) is
    // the Swift hand enum TaskBoardGitHubMergeMethod.
    ("GitHubMergeMethod", "TaskBoardGitHubMergeMethod"),
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
        .map_or(false, |(key, _)| !key.contains('['));
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
    derive_idents(attrs).iter().any(|derive| derive == "Default")
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
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            let is_default = meta.path.is_ident("default");
            let is_rename = meta.path.is_ident("rename");
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
                    }
                }
            }
            Ok(())
        });
    }
    SerdeField { rename, default_fn, has_default, flatten }
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
            if (call.method == "to_string" || call.method == "to_owned") && call.args.is_empty() =>
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
                    if let Expr::Lit(literal) = item.expr.as_ref() {
                        if let Some(swift) = lit_to_swift(&literal.lit) {
                            const_literals.insert(item.ident.to_string(), swift);
                        }
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
fn build_fields(
    fields: &FieldsNamed,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
    derives_default: bool,
) -> Vec<SwiftField> {
    let mut out = Vec::new();
    for field in &fields.named {
        let name = field.ident.as_ref().expect("named field").to_string();
        let serde = serde_field(&field.attrs);
        if serde.flatten {
            // `#[serde(flatten)]` merges the referenced struct's fields into the
            // parent JSON object; Swift Codable has no flatten, so inline the
            // flattened struct's fields directly into the parent type.
            if let Some(inner) = type_ident(&field.ty).and_then(|ident| symbols.struct_fields.get(&ident)) {
                out.extend(build_fields(inner, defaults, symbols, derives_default));
            }
            continue;
        }
        let coding_key = serde.rename.clone().unwrap_or_else(|| name.clone());
        let swift_type = rust_type_to_swift(&field.ty);
        let rust_ident = type_ident(&field.ty);
        let decode_default =
            field_decode_default(&swift_type, rust_ident.as_deref(), &serde, defaults, symbols);
        let init_default = field_init_default(
            swift_type.optional,
            &decode_default,
            &swift_type.name,
            rust_ident.as_deref(),
            derives_default,
            symbols,
        );
        out.push(SwiftField {
            property: escape_keyword(snake_to_camel(&name)),
            coding_key,
            type_name: swift_type.name,
            optional: swift_type.optional,
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
    Some(SwiftStruct {
        name: swift_type_name(&item.ident.to_string(), WIRE_SUFFIXED_TYPES),
        fields: build_fields(fields, defaults, symbols, derives),
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
            (
                escape_keyword(pascal_to_camel(&name)),
                variant_wire_value(&name, rename_all.as_deref()),
            )
        })
        .collect();
    SwiftStringEnum { name: swift_type_name(&item.ident.to_string(), WIRE_SUFFIXED_TYPES), cases }
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
            VariantPayload::Fields(build_fields(fields, defaults, symbols, false))
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
fn emit_source_decls(
    out: &mut String,
    source: &str,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) {
    let file = syn::parse_file(source).expect("policy source parses");
    for item in file.items {
        match item {
            Item::Struct(item)
                if has_serde(&item.attrs) && !is_skipped_type(&item.ident.to_string()) =>
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
                if has_serde(&item.attrs) && !is_skipped_type(&item.ident.to_string()) =>
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
    match container.tag {
        Some(tag) => emit_tagged_enum(
            out,
            &build_tagged_enum(item, &tag, container.content.as_deref(), defaults, symbols),
        ),
        None => {
            let spec = build_string_enum(item);
            if OPEN_STRING_ENUMS.contains(&spec.name.as_str()) {
                emit_open_enum(out, &spec);
            } else {
                emit_string_enum(out, &spec);
            }
        }
    }
}

const POLICY_SOURCE: &str = include_str!("../src/task_board/policy.rs");
const POLICY_GRAPH_SOURCE: &str = include_str!("../src/task_board/policy_graph.rs");
const POLICY_MODELS_SOURCE: &str = include_str!("../src/task_board/policy_graph/models.rs");
const POLICY_IDS_SOURCE: &str = include_str!("../src/task_board/policy_graph/ids.rs");
const POLICY_DEFAULTS_SOURCE: &str = include_str!("../src/task_board/policy_graph/defaults.rs");
const POLICY_STORE_SOURCE: &str = include_str!("../src/task_board/policy_graph/store.rs");
const GIT_IDENTITY_DEFAULTS_SOURCE: &str =
    include_str!("../src/task_board/git_identity_defaults.rs");
const OPENROUTER_SOURCE: &str = include_str!("../src/daemon/protocol/openrouter_models.rs");
const VOICE_SOURCE: &str = include_str!("../src/daemon/protocol/voice.rs");
const AUDIT_SOURCE: &str = include_str!("../src/daemon/protocol/audit.rs");
// agent_tui: mod.rs supplies the DEFAULT_ROWS/DEFAULT_COLS consts that the
// start-request default fns resolve to (collected by the symbol table); model.rs
// holds the snapshot/request types; screen.rs holds TerminalScreenSnapshot.
const AGENT_TUI_MOD_SOURCE: &str = include_str!("../src/daemon/agent_tui/mod.rs");
const AGENT_TUI_MODEL_SOURCE: &str = include_str!("../src/daemon/agent_tui/model.rs");
const AGENT_TUI_SCREEN_SOURCE: &str = include_str!("../src/daemon/agent_tui/screen.rs");
// codex: the run snapshot subtree decodes inside ManagedAgentSnapshot.Codex;
// the file also defines its own default fn (default_codex_agent_role ->
// SessionRole::Worker) resolved by the symbol table. SessionRole and
// TimelineEntry are referenced-not-defined, so they stay unsuffixed (the hand
// Swift types).
const CODEX_SOURCE: &str = include_str!("../src/daemon/protocol/codex.rs");
// session_requests: clean serde request/response structs. Seven types are
// SKIP_TYPES (no Swift mirror); the rest reference session::types enums that
// already exist hand-written in Swift, so they stay unsuffixed references.
const SESSION_REQUESTS_SOURCE: &str =
    include_str!("../src/daemon/protocol/session_requests.rs");
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
const REVIEWS_THREAD_RESOLVE_SOURCE: &str =
    include_str!("../src/reviews/review_thread_resolve.rs");
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
const REVIEWS_FILES_LOCAL_CLONE_SOURCE: &str =
    include_str!("../src/reviews/files/local_clone.rs");
// reviews timeline: the PR timeline entries. ReviewTimelineEntry is internally
// tagged (tag="kind") wrapping newtype entry structs (the generator re-inlines
// the payload alongside the tag); the entries carry chrono DateTime, a boxed
// SimpleActorEventEntry, and a JsonValue raw payload - all handled.
const REVIEWS_TIMELINE_TYPES_SOURCE: &str = include_str!("../src/reviews/timeline/types.rs");
const REVIEWS_TIMELINE_MOD_SOURCE: &str = include_str!("../src/reviews/timeline/mod.rs");
// reviews types.rs core: the query/item/check/action/policy request-response
// surface. The custom default fns it references live in src/reviews/logic.rs
// (the defaults source). GitHubMergeMethod is referenced-not-defined (renamed to
// the hand type); ReviewAuthorAssociation references the adopted closed enum.
const REVIEWS_TYPES_SOURCE: &str = include_str!("../src/reviews/types.rs");
const REVIEWS_LOGIC_SOURCE: &str = include_str!("../src/reviews/logic.rs");
// websocket: the JSON-RPC-ish transport envelope. The five self-contained frame
// types (request/response/error/push/chunk) generate; the three config/probe/
// inspect payloads reference unmigrated persona/runtime/acp types and are SKIP'd
// until those subsystems land. serde_json::Value -> JSONValue, the request's
// trace_context is a String dict.
const WEBSOCKET_SOURCE: &str = include_str!("../src/daemon/protocol/websocket.rs");
// session tasks: the WorkItem task-board core + its review-flow structs. Fully
// self-contained (no imports; fields are primitives or in-file types). 10 structs
// generate as *Wire (generate-only); the 6 closed enums (TaskSeverity/TaskStatus/
// TaskQueuePolicy/TaskSource/ReviewVerdict/ReviewPointState) are SKIP'd - they
// carry app divergences (TaskStatus legacy-tolerant decode, TaskSeverity .title)
// so the structs reference the existing bare Swift hand enums. ReviewPoint is also
// SKIP'd (bare hand) to avoid rippling its bare use in SessionRequestsWireTypes.
const SESSION_TASKS_SOURCE: &str = include_str!("../src/session/types/tasks.rs");

/// One Rust -> Swift wire-type module: the Rust sources whose serde types are
/// emitted, zero or more defaults sources informing decode defaults, a short
/// description woven into the generated header, and the checked-in output path
/// (relative to the crate root).
struct GeneratedModule {
    output: &'static str,
    description: &'static str,
    defaults: &'static [&'static str],
    sources: &'static [&'static str],
}

/// Every generated Swift wire-type module. Add an entry here to bring another
/// daemon subsystem under generation; `codegen` writes each file and
/// `codegen:check` fails when any drifts from its Rust sources.
fn modules() -> Vec<GeneratedModule> {
    vec![
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorPolicyModels/Generated/PolicyGraphWireTypes.generated.swift",
            description: "the Rust policy-graph wire types",
            defaults: &[POLICY_DEFAULTS_SOURCE],
            sources: &[
                POLICY_IDS_SOURCE,
                POLICY_SOURCE,
                POLICY_GRAPH_SOURCE,
                POLICY_MODELS_SOURCE,
                POLICY_STORE_SOURCE,
            ],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitWireTypes.generated.swift",
            description: "the Rust task-board git identity sources",
            defaults: &[GIT_IDENTITY_DEFAULTS_SOURCE],
            sources: &[GIT_IDENTITY_DEFAULTS_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/OpenRouterWireTypes.generated.swift",
            description: "the Rust OpenRouter model catalog",
            defaults: &[],
            sources: &[OPENROUTER_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/VoiceWireTypes.generated.swift",
            description: "the Rust voice session protocol",
            defaults: &[VOICE_SOURCE],
            sources: &[VOICE_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AuditWireTypes.generated.swift",
            description: "the Rust audit events protocol",
            defaults: &[AUDIT_SOURCE],
            sources: &[AUDIT_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/AgentTuiWireTypes.generated.swift",
            description: "the Rust managed terminal agent protocol",
            defaults: &[AGENT_TUI_MODEL_SOURCE],
            sources: &[
                AGENT_TUI_MOD_SOURCE,
                AGENT_TUI_SCREEN_SOURCE,
                AGENT_TUI_MODEL_SOURCE,
            ],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/CodexWireTypes.generated.swift",
            description: "the Rust codex run protocol",
            defaults: &[CODEX_SOURCE],
            sources: &[CODEX_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionRequestsWireTypes.generated.swift",
            description: "the Rust session request protocol",
            defaults: &[SESSION_REQUESTS_SOURCE],
            sources: &[SESSION_REQUESTS_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsEnums.generated.swift",
            description: "the Rust reviews wire enums",
            defaults: &[],
            sources: &[REVIEWS_ENUMS_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsLeavesWireTypes.generated.swift",
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
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsFilesWireTypes.generated.swift",
            description:
                "the Rust reviews file list, patch, preview, blob, viewed and local-clone types",
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
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsTimelineWireTypes.generated.swift",
            description: "the Rust reviews pull request timeline types",
            defaults: &[],
            sources: &[REVIEWS_TIMELINE_TYPES_SOURCE, REVIEWS_TIMELINE_MOD_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/ReviewsTypesWireTypes.generated.swift",
            description: "the Rust reviews query, item, check, action and policy types",
            defaults: &[REVIEWS_LOGIC_SOURCE],
            sources: &[REVIEWS_TYPES_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/WebSocketWireTypes.generated.swift",
            description: "the Rust websocket transport frame types",
            defaults: &[],
            sources: &[WEBSOCKET_SOURCE],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/SessionTasksWireTypes.generated.swift",
            description: "the Rust session work-item and review-flow types",
            defaults: &[SESSION_TASKS_SOURCE],
            sources: &[SESSION_TASKS_SOURCE],
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
        "// Generated by examples/policy-codegen.rs from {}\n\
         // Do not edit by hand - rerun: mise run codegen\n\n\
         import Foundation\n",
        module.description
    );
    for source in module.sources {
        emit_source_decls(&mut out, source, &defaults, &symbols);
    }
    out
}

/// Generate the policy-graph module. Retained for the emitter unit tests.
#[cfg(test)]
fn generate_policy_swift() -> String {
    generate_module(&modules()[0])
}

fn main() {
    let check = std::env::args().any(|arg| arg == "--check");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut drifted: Vec<&str> = Vec::new();
    for module in modules() {
        let generated = generate_module(&module);
        let path = root.join(module.output);
        if check {
            let committed = fs::read_to_string(&path).unwrap_or_default();
            if committed != generated {
                drifted.push(module.output);
            }
        } else {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("create generated module directory");
            }
            fs::write(&path, generated).expect("write generated Swift module");
        }
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
    fn emits_string_backed_enum_with_snake_case_raw_values() {
        let spec = SwiftStringEnum {
            name: "PolicyGraphMode".to_string(),
            cases: vec![
                ("draft".to_string(), "draft".to_string()),
                ("dryRun".to_string(), "dry_run".to_string()),
                ("enforced".to_string(), "enforced".to_string()),
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
                ("none".to_string(), "none".to_string()),
                ("ssh".to_string(), "ssh".to_string()),
                ("gpg".to_string(), "gpg".to_string()),
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
                ("mergeable".to_string(), "mergeable".to_string()),
                ("conflicting".to_string(), "conflicting".to_string()),
                ("unknown".to_string(), "unknown".to_string()),
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
    fn pascal_to_camel_lowercases_first_letter() {
        assert_eq!(pascal_to_camel("DryRun"), "dryRun");
        assert_eq!(pascal_to_camel("OcrImage"), "ocrImage");
        assert_eq!(pascal_to_camel("Hub"), "hub");
    }

    #[test]
    fn variant_wire_value_respects_rename_all() {
        assert_eq!(variant_wire_value("SpeechToText", Some("camelCase")), "speechToText");
        assert_eq!(variant_wire_value("SpeechToText", Some("snake_case")), "speech_to_text");
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
                ("speechToText".to_string(), "speechToText".to_string()),
                ("raw".to_string(), "raw".to_string()),
            ]
        );
    }

    #[test]
    fn pascal_to_snake_matches_serde_rename_all() {
        assert_eq!(pascal_to_snake("DryRun"), "dry_run");
        assert_eq!(pascal_to_snake("ReviewScreenshotPaste"), "review_screenshot_paste");
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
    fn maps_hash_and_btree_maps_to_dictionaries() {
        assert_eq!(swift_type_string("BTreeMap<String, usize>"), "[String: UInt]");
        assert_eq!(swift_type_string("HashMap<String, String>"), "[String: String]");
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
        assert_eq!(empty_collection_literal("[String: [ReviewRepositoryLabelWire]]"), "[:]");
        assert_eq!(empty_collection_literal("[[String: UInt]]"), "[]");
    }

    #[test]
    fn unwraps_box_to_the_inner_type() {
        // Use sample names absent from WIRE_SUFFIXED_TYPES so the Box unwrap is
        // tested in isolation from the suffix logic.
        assert_eq!(swift_type_string("Box<BoxedSample>"), "BoxedSample");
        assert_eq!(swift_type_string("Box<String>"), "String");
        assert_eq!(swift_type_string("Option<Box<BoxedSample>>"), "BoxedSample?");
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

        let properties: Vec<_> = spec.fields.iter().map(|field| field.property.as_str()).collect();
        assert_eq!(properties, vec!["id", "starred", "draft", "trailing"]);
        let coding_keys: Vec<_> = spec.fields.iter().map(|field| field.coding_key.as_str()).collect();
        assert_eq!(coding_keys, vec!["id", "starred", "is_draft", "trailing"]);
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
        assert_eq!(swift_type_name("HarnessCodeLanguage", &[]), "HarnessReviewFileLanguage");
    }

    #[test]
    fn maps_named_types_unchanged() {
        assert_eq!(swift_type_string("PolicyEvidenceField"), "PolicyEvidenceField");
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
        assert_eq!(defaults.get("default_label"), Some(&"\"draft\"".to_string()));
    }

    #[test]
    fn generates_swift_for_real_policy_sources() {
        let swift = generate_policy_swift();

        assert!(swift.starts_with("// Generated by examples/policy-codegen.rs"));
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

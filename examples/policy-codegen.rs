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

/// A generated Swift enum mirroring a Rust internally-tagged enum: associated
/// values inline (no `indirect` boxing) with a discriminator-switched Codable.
struct SwiftTaggedEnum {
    name: String,
    tag: String,
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
    if symbols.structs_with_default.contains(type_name) {
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
        emit_variant_decode(out, variant);
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

fn emit_variant_decode(out: &mut String, variant: &SwiftTaggedVariant) {
    match &variant.payload {
        VariantPayload::Unit => {
            writeln!(out, "      self = .{}", variant.case_name).unwrap();
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
        VariantPayload::Newtype(inner) => {
            writeln!(out, "      self = .{}(try {}(from: decoder))", variant.case_name, inner).unwrap();
        }
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
        emit_variant_encode(out, variant, &spec.tag);
    }
    out.push_str("    }\n");
    out.push_str("  }\n");
}

fn emit_variant_encode(out: &mut String, variant: &SwiftTaggedVariant, tag: &str) {
    match &variant.payload {
        VariantPayload::Unit => {
            writeln!(out, "    case .{}:", variant.case_name).unwrap();
            writeln!(out, "      try container.encode(\"{}\", forKey: .{})", variant.raw_tag, tag).unwrap();
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
            out.push_str("      try value.encode(to: encoder)\n");
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

/// Map a Rust scalar to its smallest faithful Swift type; pass named types
/// (other generated wire types) through unchanged.
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
        other => other,
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

/// The Swift zero value for a scalar or array type, used to default the
/// required fields of `Default`-deriving structs.
fn zero_value(swift_type: &str) -> Option<String> {
    if swift_type.starts_with('[') {
        return Some("[]".to_string());
    }
    let value = match swift_type {
        "Bool" => "false",
        "String" => "\"\"",
        "Float" | "Double" | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt" | "UInt8"
        | "UInt16" | "UInt32" | "UInt64" => "0",
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
/// `#[default]` variant (as a Swift case) and the structs that derive `Default`
/// (so a zero-argument initializer exists to call).
struct SymbolTable {
    enum_default_variant: HashMap<String, String>,
    structs_with_default: HashSet<String>,
}

/// The serde container config read from a type's attributes.
struct SerdeContainer {
    tag: Option<String>,
}

/// The serde field config read from a field's attributes.
struct SerdeField {
    rename: Option<String>,
    default_fn: Option<String>,
    has_default: bool,
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

/// Read `#[serde(tag = "...")]` from a type's attributes.
fn serde_container(attrs: &[Attribute]) -> SerdeContainer {
    let mut tag = None;
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let _ = attr.parse_nested_meta(|meta| {
            let is_tag = meta.path.is_ident("tag");
            if let Ok(value) = meta.value() {
                let lit: Lit = value.parse()?;
                if is_tag {
                    if let Lit::Str(text) = lit {
                        tag = Some(text.value());
                    }
                }
            }
            Ok(())
        });
    }
    SerdeContainer { tag }
}

/// Read `#[serde(rename = ..., default[ = "..."])]` from a field's attributes.
fn serde_field(attrs: &[Attribute]) -> SerdeField {
    let mut rename = None;
    let mut default_fn = None;
    let mut has_default = false;
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
    SerdeField { rename, default_fn, has_default }
}

/// Parse `defaults.rs`, mapping each zero-argument default function to the Swift
/// literal it returns. The `is_default_*` predicate helpers take a parameter and
/// are skipped.
fn parse_defaults(source: &str) -> DefaultLiterals {
    let file = syn::parse_file(source).expect("defaults.rs parses");
    let mut literals = DefaultLiterals::new();
    for item in file.items {
        let Item::Fn(function) = item else {
            continue;
        };
        if !function.sig.inputs.is_empty() {
            continue;
        }
        if let Some(literal) = block_literal(&function.block) {
            literals.insert(function.sig.ident.to_string(), literal);
        }
    }
    literals
}

/// The Swift literal returned by a single-expression function body.
fn block_literal(block: &syn::Block) -> Option<String> {
    let [Stmt::Expr(expr, _)] = block.stmts.as_slice() else {
        return None;
    };
    expr_literal(expr)
}

/// Render a literal expression (including `"...".to_string()`) as Swift.
fn expr_literal(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Lit(literal) => lit_to_swift(&literal.lit),
        Expr::MethodCall(call) if call.method == "to_string" && call.args.is_empty() => {
            expr_literal(&call.receiver)
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
    for source in sources {
        let file = syn::parse_file(source).expect("policy source parses");
        for item in file.items {
            match item {
                Item::Struct(item) if derives_default(&item.attrs) => {
                    structs_with_default.insert(item.ident.to_string());
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
                _ => {}
            }
        }
    }
    SymbolTable { enum_default_variant, structs_with_default }
}

/// Build Swift field descriptors from named Rust fields.
fn build_fields(
    fields: &FieldsNamed,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
    derives_default: bool,
) -> Vec<SwiftField> {
    fields
        .named
        .iter()
        .map(|field| {
            let name = field.ident.as_ref().expect("named field").to_string();
            let serde = serde_field(&field.attrs);
            let coding_key = serde.rename.clone().unwrap_or_else(|| name.clone());
            let swift_type = rust_type_to_swift(&field.ty);
            let decode_default = field_decode_default(&swift_type, &serde, defaults, symbols);
            let init_default = field_init_default(
                swift_type.optional,
                &decode_default,
                &swift_type.name,
                derives_default,
                symbols,
            );
            SwiftField {
                property: escape_keyword(snake_to_camel(&name)),
                coding_key,
                type_name: swift_type.name,
                optional: swift_type.optional,
                decode_default,
                init_default,
            }
        })
        .collect()
}

/// The decoder fallback (`?? value`) for a field, or `None` when a synthesized
/// optional decode or a plain required decode is correct.
fn field_decode_default(
    swift_type: &SwiftType,
    serde: &SerdeField,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> Option<String> {
    if !serde.has_default || swift_type.optional {
        return None;
    }
    if swift_type.name.starts_with('[') {
        return Some("[]".to_string());
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
    if let Some(variant) = symbols.enum_default_variant.get(&swift_type.name) {
        return Some(format!(".{variant}"));
    }
    if symbols.structs_with_default.contains(&swift_type.name) {
        return Some(format!("{}()", swift_type.name));
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
        name: item.ident.to_string(),
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
            (escape_keyword(pascal_to_camel(&name)), pascal_to_snake(&name))
        })
        .collect();
    SwiftStringEnum { name: item.ident.to_string(), cases }
}

/// Build an internally-tagged enum descriptor from a `#[serde(tag = ...)]` enum.
fn build_tagged_enum(
    item: &ItemEnum,
    tag: &str,
    defaults: &DefaultLiterals,
    symbols: &SymbolTable,
) -> SwiftTaggedEnum {
    let variants = item
        .variants
        .iter()
        .map(|variant| build_tagged_variant(variant, defaults, symbols))
        .collect();
    SwiftTaggedEnum { name: item.ident.to_string(), tag: tag.to_string(), variants }
}

/// Build one tagged-enum variant descriptor, inlining the payload shape.
fn build_tagged_variant(
    variant: &Variant,
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
        raw_tag: pascal_to_snake(&name),
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
            Item::Struct(item) if has_serde(&item.attrs) => {
                if let Some(spec) = build_struct(&item, defaults, symbols) {
                    out.push('\n');
                    emit_struct(out, &spec);
                } else if is_string_newtype(&item) {
                    out.push('\n');
                    emit_newtype(out, &item.ident.to_string());
                }
            }
            Item::Enum(item) if has_serde(&item.attrs) => {
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
    match serde_container(&item.attrs).tag {
        Some(tag) => emit_tagged_enum(out, &build_tagged_enum(item, &tag, defaults, symbols)),
        None => emit_string_enum(out, &build_string_enum(item)),
    }
}

/// Header prepended to the generated Swift module.
const GENERATED_HEADER: &str = "\
// Generated by examples/policy-codegen.rs from the Rust policy-graph wire types
// Do not edit by hand - rerun: mise run codegen

import Foundation
";

const GIT_HEADER: &str = "\
// Generated by examples/policy-codegen.rs from the Rust task-board git identity sources
// Do not edit by hand - rerun: mise run codegen

import Foundation
";

const POLICY_SOURCE: &str = include_str!("../src/task_board/policy.rs");
const POLICY_GRAPH_SOURCE: &str = include_str!("../src/task_board/policy_graph.rs");
const POLICY_MODELS_SOURCE: &str = include_str!("../src/task_board/policy_graph/models.rs");
const POLICY_IDS_SOURCE: &str = include_str!("../src/task_board/policy_graph/ids.rs");
const POLICY_DEFAULTS_SOURCE: &str = include_str!("../src/task_board/policy_graph/defaults.rs");
const GIT_IDENTITY_DEFAULTS_SOURCE: &str =
    include_str!("../src/task_board/git_identity_defaults.rs");

/// One Rust -> Swift wire-type module: the Rust sources whose serde types are
/// emitted, an optional defaults source informing decode defaults, the Swift
/// header, and the checked-in output path (relative to the crate root).
struct GeneratedModule {
    output: &'static str,
    header: &'static str,
    defaults: Option<&'static str>,
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
            header: GENERATED_HEADER,
            defaults: Some(POLICY_DEFAULTS_SOURCE),
            sources: &[
                POLICY_IDS_SOURCE,
                POLICY_SOURCE,
                POLICY_GRAPH_SOURCE,
                POLICY_MODELS_SOURCE,
            ],
        },
        GeneratedModule {
            output:
                "apps/harness-monitor/Sources/HarnessMonitorKit/Models/Generated/TaskBoardGitWireTypes.generated.swift",
            header: GIT_HEADER,
            defaults: Some(GIT_IDENTITY_DEFAULTS_SOURCE),
            sources: &[GIT_IDENTITY_DEFAULTS_SOURCE],
        },
    ]
}

/// Generate the Swift wire-type source for one module.
///
/// The driver parses one source at a time, dropping each AST before the next, so
/// only the current file's syntax tree and one descriptor are live at once.
fn generate_module(module: &GeneratedModule) -> String {
    let defaults = parse_defaults(module.defaults.unwrap_or(""));
    let symbols = build_symbol_table(module.sources);
    let mut out = String::from(module.header);
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

use std::collections::HashMap;

use comrak::nodes::NodeValue;
use comrak::{Arena, Options, parse_document};
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

/// Extract raw frontmatter YAML text and body from a markdown document.
///
/// Uses comrak to locate the frontmatter block, then strips delimiters.
/// Returns `(yaml_text, body)`.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or unterminated.
pub fn extract_raw_frontmatter(text: &str) -> Result<(String, String), CliError> {
    let mut options = Options::default();
    options.extension.front_matter_delimiter = Some("---".to_owned());

    let arena = Arena::new();
    let root = parse_document(&arena, text, &options);

    let fm_content = root.descendants().find_map(|node| {
        let data = node.data.borrow();
        if let NodeValue::FrontMatter(ref content) = data.value {
            Some(content.clone())
        } else {
            None
        }
    });

    let Some(raw_fm) = fm_content else {
        return if text.starts_with("---\n") {
            Err(CliErrorKind::UnterminatedFrontmatter.into())
        } else {
            Err(CliErrorKind::MissingFrontmatter.into())
        };
    };

    // Strip the `---\n ... \n---\n` delimiters to get bare YAML.
    let yaml_text = raw_fm.strip_prefix("---\n").unwrap_or(&raw_fm);
    let yaml_text = if let Some(pos) = yaml_text.rfind("\n---") {
        &yaml_text[..pos]
    } else {
        yaml_text
    };

    // The body is everything after the frontmatter block.
    let body = &text[raw_fm.len()..];
    let body = body.trim_start_matches('\n');

    Ok((yaml_text.to_string(), body.to_string()))
}

/// Parse markdown frontmatter into generic JSON values using comrak for
/// extraction and `serde_yml` for YAML parsing. Returns key-value pairs as
/// `HashMap<String, serde_json::Value>` and the body text.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or malformed.
pub fn parse_frontmatter_values(text: &str) -> Result<(HashMap<String, Value>, String), CliError> {
    let (yaml_text, body) = extract_raw_frontmatter(text)?;

    let yaml_value: serde_yml::Value = serde_yml::from_str(&yaml_text).map_err(|e| {
        CliErrorKind::UnterminatedFrontmatter.with_details(format!("YAML parse error: {e}"))
    })?;
    let map = yaml_to_json_map(&yaml_value);
    Ok((map, body))
}

pub(super) fn yaml_to_json_map(yaml: &serde_yml::Value) -> HashMap<String, Value> {
    let mut result = HashMap::new();
    if let serde_yml::Value::Mapping(mapping) = yaml {
        for (k, v) in mapping {
            if let serde_yml::Value::String(key) = k {
                result.insert(key.clone(), yaml_to_json(v));
            }
        }
    }
    result
}

/// YAML 1.1 boolean literals that `serde_yml` (YAML 1.2) treats as strings.
fn yaml11_bool(s: &str) -> Option<bool> {
    match s.to_lowercase().as_str() {
        "yes" | "on" => Some(true),
        "no" | "off" => Some(false),
        _ => None,
    }
}

#[must_use]
pub fn yaml_to_json(yaml: &serde_yml::Value) -> Value {
    match yaml {
        serde_yml::Value::Null => Value::Null,
        serde_yml::Value::Bool(b) => Value::Bool(*b),
        serde_yml::Value::String(s) => match yaml11_bool(s) {
            Some(b) => Value::Bool(b),
            None => Value::String(s.clone()),
        },
        serde_yml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Number(i.into())
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number)
            } else {
                Value::Null
            }
        }
        serde_yml::Value::Sequence(seq) => Value::Array(seq.iter().map(yaml_to_json).collect()),
        serde_yml::Value::Mapping(m) => {
            let mut map = serde_json::Map::new();
            for (k, v) in m {
                if let serde_yml::Value::String(key) = k {
                    map.insert(key.clone(), yaml_to_json(v));
                }
            }
            Value::Object(map)
        }
        serde_yml::Value::Tagged(tagged) => yaml_to_json(&tagged.value),
    }
}

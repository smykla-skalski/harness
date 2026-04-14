use std::fmt::Write as _;

/// Render a scalar field.
pub(super) fn push_field(s: &mut String, key: &str, value: &str) {
    let _ = writeln!(s, "{key}: {value}");
}

/// Render a boolean field.
pub(super) fn push_bool(s: &mut String, key: &str, value: bool) {
    let _ = writeln!(s, "{key}: {value}");
}

/// Render a list field. Empty lists use inline `[]` syntax.
pub(super) fn push_str_list(s: &mut String, key: &str, values: &[String]) {
    if values.is_empty() {
        let _ = writeln!(s, "{key}: []");
    } else if values.len() <= 4
        && values
            .iter()
            .all(|value| !value.contains(',') && value.len() < 30)
    {
        let joined = values.join(", ");
        let _ = writeln!(s, "{key}: [{joined}]");
    } else {
        let _ = writeln!(s, "{key}:");
        for value in values {
            let _ = writeln!(s, "  - {value}");
        }
    }
}

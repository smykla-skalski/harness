pub(crate) fn redact_secret_detail(detail: &str) -> String {
    let mut redacted = String::with_capacity(detail.len());
    let mut offset = 0;

    while offset < detail.len() {
        let rest = &detail[offset..];
        if let Some(key) = ["secret=", "token="]
            .into_iter()
            .find(|key| rest.starts_with(key))
        {
            redacted.push_str(key);
            redacted.push_str("<redacted>");
            offset += key.len();
            while let Some(value_char) = detail[offset..].chars().next() {
                if is_secret_value_terminator(value_char) {
                    break;
                }
                offset += value_char.len_utf8();
            }
        } else if let Some(plain_char) = rest.chars().next() {
            redacted.push(plain_char);
            offset += plain_char.len_utf8();
        }
    }

    redacted
}

fn is_secret_value_terminator(value_char: char) -> bool {
    value_char.is_whitespace()
        || matches!(value_char, '&' | ';' | ',' | ')' | ']' | '}' | '"' | '\'')
}

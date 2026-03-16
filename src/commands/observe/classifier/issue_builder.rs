/// Build an Issue with sensible defaults (fixable=false, no `fix_target`/`fix_hint`).
/// Optional trailing named fields override the defaults.
macro_rules! issue {
    ($line:expr, $role:expr, $text:expr, $cat:ident, $sev:ident, $summary:expr) => {
        $crate::commands::observe::types::Issue {
            line: $line,
            category: $crate::commands::observe::types::IssueCategory::$cat,
            severity: $crate::commands::observe::types::IssueSeverity::$sev,
            summary: String::from($summary),
            details: $crate::commands::observe::truncate_details($text),
            source_role: $role,
            fixable: false,
            fix_target: None,
            fix_hint: None,
        }
    };
    ($line:expr, $role:expr, $text:expr, $cat:ident, $sev:ident, $summary:expr,
     $($field:ident : $val:expr),+ $(,)?) => {{
        #[allow(unused_mut)]
        let mut i = issue!($line, $role, $text, $cat, $sev, $summary);
        $(issue!(@set i, $field, $val);)+
        i
    }};
    (@set $i:ident, fixable, $val:expr) => { $i.fixable = $val; };
    (@set $i:ident, fix_target, $val:expr) => { $i.fix_target = Some(String::from($val)); };
    (@set $i:ident, fix_hint, $val:expr) => { $i.fix_hint = Some(String::from($val)); };
}

pub(super) use issue;

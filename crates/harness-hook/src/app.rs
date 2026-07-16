use std::env;
use std::path::PathBuf;

use crate::workspace::canonical_checkout_root;

pub fn resolve_project_dir(raw: Option<&str>) -> PathBuf {
    let path = raw.filter(|value| !value.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    );
    canonical_checkout_root(&path)
}

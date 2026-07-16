use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

const AUXILIARY_EXEC_NAMES: [&str; 6] = [
    "ExecStartPre",
    "ExecStartPost",
    "ExecCondition",
    "ExecReload",
    "ExecStop",
    "ExecStopPost",
];

pub(super) fn validate_source_contract(contents: &str) -> Result<PathBuf, CliError> {
    let service = section_directives(contents, "Service")?;
    let install = section_directives(contents, "Install")?;
    let exec_start = require_single_directive(&service, "ExecStart")?;
    let arguments = shell_words::split(exec_start).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "parse managed systemd ExecStart: {error}"
        )))
    })?;
    let [binary, remote, serve, ..] = arguments.as_slice() else {
        return Err(workflow_io(
            "managed systemd ExecStart must run harness-daemon remote serve",
        ));
    };
    if [remote.as_str(), serve.as_str()] != ["remote", "serve"] {
        return Err(workflow_io(
            "managed systemd ExecStart must run harness-daemon remote serve",
        ));
    }
    let binary = PathBuf::from(binary);
    if !binary.is_absolute() {
        return Err(workflow_io(format!(
            "managed systemd ExecStart binary must be absolute: {}",
            binary.display()
        )));
    }
    reject_source_auxiliaries(&service)?;
    require_optional_single_directive(&service, "KillMode", "control-group")?;
    require_exact_install_contract(&install)?;
    Ok(binary)
}

pub(super) fn validate_effective_exec_contract(
    stdout: &str,
    binary_path: &Path,
) -> Result<(), CliError> {
    let exec_start = parse_exec_start(required_property(stdout, "ExecStart")?)?;
    let expected = binary_path.to_str().ok_or_else(|| {
        workflow_io(format!(
            "managed systemd binary path is not UTF-8: {}",
            binary_path.display()
        ))
    })?;
    let expected_prefix = [expected, "remote", "serve"];
    if exec_start.path != expected
        || !exec_start
            .arguments
            .iter()
            .map(String::as_str)
            .take(expected_prefix.len())
            .eq(expected_prefix)
    {
        return Err(workflow_io(format!(
            "effective systemd ExecStart must run {} remote serve, found path={:?} argv={:?}",
            binary_path.display(),
            exec_start.path,
            exec_start.arguments
        )));
    }
    require_property(stdout, "KillMode", "control-group")?;
    for key in AUXILIARY_EXEC_NAMES {
        require_auxiliary_absent(stdout, key)?;
    }
    Ok(())
}

fn require_auxiliary_absent(stdout: &str, key: &str) -> Result<(), CliError> {
    let values = stdout
        .lines()
        .filter_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    match values.as_slice() {
        [] | [""] => Ok(()),
        [value] if value.trim().is_empty() => Ok(()),
        [value] => Err(workflow_io(format!(
            "effective systemd unit must not define privileged auxiliary {key}={value}"
        ))),
        _ => Err(workflow_io(format!(
            "systemctl show must return at most one {key} property, found {}",
            values.len()
        ))),
    }
}

fn section_directives(contents: &str, section: &str) -> Result<Vec<(String, String)>, CliError> {
    let expected_header = format!("[{section}]");
    let mut section_count = 0_u8;
    let mut in_section = false;
    let mut directives = Vec::new();
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_section = trimmed == expected_header;
            if in_section {
                section_count = section_count.saturating_add(1);
            }
            continue;
        }
        if !in_section || trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';')
        {
            continue;
        }
        let Some((key, value)) = trimmed.split_once('=') else {
            return Err(workflow_io(format!(
                "managed systemd [{section}] contains an invalid directive: {trimmed}"
            )));
        };
        directives.push((key.trim().to_string(), value.trim().to_string()));
    }
    if section_count == 1 {
        Ok(directives)
    } else {
        Err(workflow_io(format!(
            "managed systemd unit must contain exactly one [{section}] section, found {section_count}"
        )))
    }
}

fn require_exact_install_contract(directives: &[(String, String)]) -> Result<(), CliError> {
    if directives.len() == 1
        && directives[0].0 == "WantedBy"
        && directives[0].1 == "multi-user.target"
    {
        Ok(())
    } else {
        Err(workflow_io(format!(
            "managed systemd [Install] must contain exactly WantedBy=multi-user.target, found {directives:?}"
        )))
    }
}

fn reject_source_auxiliaries(directives: &[(String, String)]) -> Result<(), CliError> {
    if let Some((key, value)) = directives
        .iter()
        .find(|(key, _)| key.starts_with("Exec") && key != "ExecStart")
    {
        Err(workflow_io(format!(
            "managed systemd unit must not define privileged auxiliary {key}={value}"
        )))
    } else {
        Ok(())
    }
}

fn require_single_directive<'a>(
    directives: &'a [(String, String)],
    key: &str,
) -> Result<&'a str, CliError> {
    let values = directive_values(directives, key);
    let [value] = values.as_slice() else {
        return Err(workflow_io(format!(
            "managed systemd unit requires exactly one {key}, found {values:?}"
        )));
    };
    Ok(value)
}

fn require_optional_single_directive(
    directives: &[(String, String)],
    key: &str,
    expected: &str,
) -> Result<(), CliError> {
    let values = directive_values(directives, key);
    if values.is_empty() || values == [expected] {
        Ok(())
    } else {
        Err(workflow_io(format!(
            "managed systemd unit permits only {key}={expected}, found {values:?}"
        )))
    }
}

fn directive_values<'a>(directives: &'a [(String, String)], key: &str) -> Vec<&'a str> {
    directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == key).then_some(value.as_str()))
        .collect()
}

fn require_property(stdout: &str, key: &str, expected: &str) -> Result<(), CliError> {
    let observed = required_property(stdout, key)?;
    if observed == expected {
        Ok(())
    } else {
        Err(workflow_io(format!(
            "effective systemd unit requires {key}={expected}, found {observed}"
        )))
    }
}

fn required_property<'a>(stdout: &'a str, key: &str) -> Result<&'a str, CliError> {
    let values = stdout
        .lines()
        .filter_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    let [value] = values.as_slice() else {
        return Err(workflow_io(format!(
            "systemctl show must return exactly one {key} property, found {}",
            values.len()
        )));
    };
    Ok(value)
}

struct ParsedExecStart {
    path: String,
    arguments: Vec<String>,
}

fn parse_exec_start(value: &str) -> Result<ParsedExecStart, CliError> {
    let body = value
        .trim()
        .strip_prefix('{')
        .and_then(|value| value.strip_suffix('}'))
        .ok_or_else(|| workflow_io(format!("parse effective systemd ExecStart record: {value}")))?;
    if body.contains('{') || body.contains('}') {
        return Err(workflow_io(format!(
            "effective systemd ExecStart must contain exactly one command record: {value}"
        )));
    }
    let mut path = None;
    let mut arguments = None;
    for field in body
        .split(';')
        .map(str::trim)
        .filter(|field| !field.is_empty())
    {
        let Some((key, value)) = field.split_once('=') else {
            return Err(workflow_io(format!(
                "parse effective systemd ExecStart field: {field}"
            )));
        };
        match key.trim() {
            "path" => set_single_field(&mut path, parse_path(value)?, "path")?,
            "argv[]" => set_single_field(
                &mut arguments,
                shell_words::split(value).map_err(|error| {
                    workflow_io(format!("parse effective systemd ExecStart argv: {error}"))
                })?,
                "argv[]",
            )?,
            _ => {}
        }
    }
    Ok(ParsedExecStart {
        path: path.ok_or_else(|| workflow_io("effective systemd ExecStart omitted path"))?,
        arguments: arguments
            .ok_or_else(|| workflow_io("effective systemd ExecStart omitted argv[]"))?,
    })
}

fn parse_path(value: &str) -> Result<String, CliError> {
    let values = shell_words::split(value)
        .map_err(|error| workflow_io(format!("parse effective systemd ExecStart path: {error}")))?;
    let [path] = values.as_slice() else {
        return Err(workflow_io(format!(
            "effective systemd ExecStart path must contain one value, found {values:?}"
        )));
    };
    Ok(path.clone())
}

fn set_single_field<T>(slot: &mut Option<T>, value: T, name: &str) -> Result<(), CliError> {
    if slot.replace(value).is_some() {
        Err(workflow_io(format!(
            "effective systemd ExecStart contains duplicate {name}"
        )))
    } else {
        Ok(())
    }
}

fn workflow_io(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::validate_effective_exec_contract;

    const BINARY: &str = "/usr/local/bin/harness-daemon";

    #[test]
    fn omitted_empty_auxiliary_properties_are_accepted() {
        let stdout = format!(
            "KillMode=control-group\nExecStart={{ path={BINARY} ; argv[]={BINARY} remote serve ; }}\n"
        );
        validate_effective_exec_contract(&stdout, Path::new(BINARY))
            .expect("omitted empty auxiliary properties");
    }

    #[test]
    fn nonempty_or_duplicate_auxiliary_properties_are_rejected() {
        const NONEMPTY: &str = "ExecStop={ path=/bin/true ; }\n";
        const DUPLICATE: &str = "ExecStop=\nExecStop=\n";
        for suffix in [NONEMPTY, DUPLICATE] {
            let stdout = format!(
                "KillMode=control-group\nExecStart={{ path={BINARY} ; argv[]={BINARY} remote serve ; }}\n{suffix}"
            );
            validate_effective_exec_contract(&stdout, Path::new(BINARY))
                .expect_err("unsafe auxiliary serialization");
        }
    }
}

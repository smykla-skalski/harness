use std::io::{BufRead, BufReader, Read as _, Seek as _, SeekFrom};
use std::mem;
use std::path::Path;

use fs_err as fs;
use serde::de::DeserializeOwned;

use crate::errors::{CliError, CliErrorKind};

pub(super) fn read_json_lines<T>(path: &Path, label: &str) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let mut values = Vec::new();
    for_each_nonempty_line(path, label, |line, _line_number| {
        let value = serde_json::from_str(line).map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!("{label}: {error}")))
        })?;
        values.push(value);
        Ok(())
    })?;
    Ok(values)
}

pub(super) fn for_each_nonempty_line<F>(
    path: &Path,
    label: &str,
    mut visitor: F,
) -> Result<(), CliError>
where
    F: FnMut(&str, usize) -> Result<(), CliError>,
{
    let file = fs::File::open(path)
        .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut line_number = 0usize;

    loop {
        line.clear();
        let bytes_read = reader
            .read_line(&mut line)
            .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?;
        if bytes_read == 0 {
            return Ok(());
        }
        line_number = line_number.saturating_add(1);
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.trim().is_empty() {
            continue;
        }
        visitor(trimmed, line_number)?;
    }
}

pub(super) fn read_last_nonempty_line(
    path: &Path,
    label: &str,
) -> Result<Option<String>, CliError> {
    if !path.is_file() {
        return Ok(None);
    }

    let mut file = fs::File::open(path)
        .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?;
    let mut position = file
        .metadata()
        .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?
        .len();
    if position == 0 {
        return Ok(None);
    }

    let mut chunk = vec![0_u8; 8 * 1024];
    let mut line_bytes = Vec::new();
    while position > 0 {
        let read_len = usize::try_from(position.min(chunk.len() as u64)).unwrap_or(chunk.len());
        position = position.saturating_sub(u64::try_from(read_len).unwrap_or(0));
        file.seek(SeekFrom::Start(position))
            .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?;
        file.read_exact(&mut chunk[..read_len])
            .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?;
        for &byte in chunk[..read_len].iter().rev() {
            if byte == b'\n' {
                if let Some(line) = decode_tail_line(&mut line_bytes, label)? {
                    return Ok(Some(line));
                }
                continue;
            }
            line_bytes.push(byte);
        }
    }

    decode_tail_line(&mut line_bytes, label)
}

fn decode_tail_line(line_bytes: &mut Vec<u8>, label: &str) -> Result<Option<String>, CliError> {
    if line_bytes.is_empty() {
        return Ok(None);
    }

    line_bytes.reverse();
    let line = String::from_utf8(mem::take(line_bytes)).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "{label}: invalid utf-8 line: {error}"
        )))
    })?;
    let trimmed = line.trim_end_matches('\r');
    if trimmed.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(trimmed.to_string()))
}

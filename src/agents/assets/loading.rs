use std::fs::DirEntry;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, validate_safe_segment};

use super::files::io_err;
use super::model::{
    PLUGINS_ROOT, PluginDefinition, PluginSource, SKILLS_ROOT, SkillDefinition, SkillSource,
    SkillVariant,
};

pub(super) fn load_skill_sources(repo_root: &Path) -> Result<Vec<SkillDefinition>, CliError> {
    let root = repo_root.join(SKILLS_ROOT);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut skills = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if !entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            continue;
        }
        if is_skill_creator_workspace(&entry) {
            continue;
        }
        skills.push(load_skill_definition(entry.path())?);
    }
    skills.sort_by(|a, b| a.source.name.cmp(&b.source.name));
    Ok(skills)
}

/// Skip `<name>-workspace/` directories created by the skill-creator workflow.
/// They live as siblings of the canonical skill source per the skill-creator
/// convention and are not themselves skills, so the loader must not try to
/// read `skill.yaml` from them.
fn is_skill_creator_workspace(entry: &DirEntry) -> bool {
    entry
        .file_name()
        .to_str()
        .is_some_and(|name| name.ends_with("-workspace"))
}

pub(super) fn load_plugin_sources(
    repo_root: &Path,
    shared_skills: &[SkillDefinition],
) -> Result<Vec<PluginDefinition>, CliError> {
    let root = repo_root.join(PLUGINS_ROOT);
    let mut plugins = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if !entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            continue;
        }
        let plugin_root = entry.path();
        let source = load_plugin_source(&plugin_root)?;
        let hooks = {
            let path = plugin_root.join("hooks.yaml");
            path.exists().then(|| read_text(&path)).transpose()?
        };
        let mut skills = Vec::new();
        let plugin_skills_root = plugin_root.join("skills");
        if plugin_skills_root.is_dir() {
            for skill_dir in plugin_skills_root
                .read_dir()
                .map_err(|error| io_err(&error))?
            {
                let skill_dir = skill_dir.map_err(|error| io_err(&error))?;
                if !skill_dir
                    .file_type()
                    .map_err(|error| io_err(&error))?
                    .is_dir()
                {
                    continue;
                }
                if is_skill_creator_workspace(&skill_dir) {
                    continue;
                }
                skills.push(load_skill_definition(skill_dir.path())?);
            }
        }
        if let Some(skill_name) = source.source_skill.as_deref() {
            let Some(shared) = shared_skills
                .iter()
                .find(|skill| skill.source.name == skill_name)
            else {
                return Err(CliErrorKind::usage_error(format!(
                    "plugin `{}` references missing shared skill `{skill_name}`",
                    source.name
                ))
                .into());
            };
            skills.push(shared.clone());
        }
        skills.sort_by(|a, b| a.source.name.cmp(&b.source.name));
        plugins.push(PluginDefinition {
            root: plugin_root,
            source,
            hooks,
            skills,
        });
    }
    plugins.sort_by(|a, b| a.source.name.cmp(&b.source.name));
    Ok(plugins)
}

pub(super) fn load_plugin_source(plugin_root: &Path) -> Result<PluginSource, CliError> {
    let path = plugin_root.join("plugin.yaml");
    let source: PluginSource = serde_yml::from_str(&read_text(&path)?).map_err(|error| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(error.to_string())
    })?;
    validate_safe_segment(&source.name)?;
    Ok(source)
}

pub(super) fn load_skill_definition(root: PathBuf) -> Result<SkillDefinition, CliError> {
    let source: SkillSource =
        serde_yml::from_str(&read_text(&root.join("skill.yaml"))?).map_err(|error| {
            CliErrorKind::invalid_json(root.join("skill.yaml").display().to_string())
                .with_details(error.to_string())
        })?;
    let body = read_text(&root.join("body.md"))?;
    let codex = load_skill_variant(root.join("codex"))?;
    Ok(SkillDefinition {
        root,
        source,
        body,
        codex,
    })
}

fn load_skill_variant(root: PathBuf) -> Result<Option<SkillVariant>, CliError> {
    if !root.is_dir() {
        return Ok(None);
    }
    let source: SkillSource =
        serde_yml::from_str(&read_text(&root.join("skill.yaml"))?).map_err(|error| {
            CliErrorKind::invalid_json(root.join("skill.yaml").display().to_string())
                .with_details(error.to_string())
        })?;
    let body = read_text(&root.join("body.md"))?;
    Ok(Some(SkillVariant { root, source, body }))
}

pub(super) fn discover_plugin_sources(root: &Path) -> Result<Vec<PluginSource>, CliError> {
    let mut plugins = Vec::new();
    for entry in root.read_dir().map_err(|error| io_err(&error))? {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().map_err(|error| io_err(&error))?.is_dir() {
            plugins.push(load_plugin_source(&entry.path())?);
        }
    }
    plugins.sort_by(|a, b| a.name.cmp(&b.name));
    plugins.dedup_by(|a, b| a.name == b.name);
    Ok(plugins)
}

#[cfg(test)]
mod tests {
    use std::fs::{create_dir_all, write};

    use tempfile::TempDir;

    use super::{SKILLS_ROOT, load_plugin_sources, load_skill_definition, load_skill_sources};

    #[test]
    fn load_skill_sources_returns_empty_when_shared_skills_root_is_missing() {
        let tmp = TempDir::new().expect("tempdir");
        let skills = load_skill_sources(tmp.path()).expect("missing skills root should be allowed");
        assert!(skills.is_empty());
    }

    #[test]
    fn load_skill_sources_skips_skill_creator_workspace_siblings() {
        let tmp = TempDir::new().expect("tempdir");
        let skills_root = tmp.path().join(SKILLS_ROOT);
        let skill_dir = skills_root.join("real-skill");
        create_dir_all(&skill_dir).expect("create real-skill dir");
        write(
            skill_dir.join("skill.yaml"),
            "name: real-skill\ndescription: ok\n",
        )
        .expect("write skill.yaml");
        write(skill_dir.join("body.md"), "body").expect("write body.md");

        // Sibling workspace directory created by skill-creator iterations.
        // It carries no `skill.yaml` and the loader must not try to read one.
        let workspace = skills_root.join("real-skill-workspace");
        create_dir_all(workspace.join("iteration-1")).expect("create workspace dir");
        write(workspace.join("iteration-1").join("notes.md"), "scratch")
            .expect("write workspace scratch file");

        let skills = load_skill_sources(tmp.path()).expect("loader skips workspace siblings");
        assert_eq!(skills.len(), 1);
        assert_eq!(skills[0].source.name, "real-skill");
    }

    #[test]
    fn load_plugin_sources_skips_skill_creator_workspace_under_plugin_skills() {
        let tmp = TempDir::new().expect("tempdir");
        let plugin_root = tmp.path().join("agents").join("plugins").join("demo");
        create_dir_all(plugin_root.join("skills").join("real").join("references"))
            .expect("create plugin skill dir");
        write(
            plugin_root.join("plugin.yaml"),
            "name: demo\ndescription: demo plugin\nversion: 0.1.0\n",
        )
        .expect("write plugin.yaml");
        write(
            plugin_root.join("skills").join("real").join("skill.yaml"),
            "name: real\ndescription: ok\n",
        )
        .expect("write skill.yaml");
        write(
            plugin_root.join("skills").join("real").join("body.md"),
            "body",
        )
        .expect("write body.md");

        // Sibling workspace inside the plugin's `skills/` directory.
        let workspace = plugin_root.join("skills").join("real-workspace");
        create_dir_all(workspace.join("iteration-1")).expect("create plugin workspace");
        write(workspace.join("iteration-1").join("scratch.md"), "scratch")
            .expect("write workspace scratch file");

        let plugins = load_plugin_sources(tmp.path(), &[]).expect("loader skips plugin workspaces");
        assert_eq!(plugins.len(), 1);
        let plugin = &plugins[0];
        assert_eq!(plugin.source.name, "demo");
        assert_eq!(plugin.skills.len(), 1);
        assert_eq!(plugin.skills[0].source.name, "real");
    }

    #[test]
    fn load_skill_definition_reads_codex_variant_when_present() {
        let tmp = TempDir::new().expect("tempdir");
        let skill_dir = tmp.path().join("agents").join("skills").join("real-skill");
        create_dir_all(skill_dir.join("codex")).expect("create codex variant dir");
        write(
            skill_dir.join("skill.yaml"),
            "name: real-skill\ndescription: base\nallowed-tools: Bash\n",
        )
        .expect("write base skill.yaml");
        write(skill_dir.join("body.md"), "base body").expect("write base body.md");
        write(
            skill_dir.join("codex").join("skill.yaml"),
            "name: real-skill\ndescription: codex\n",
        )
        .expect("write codex skill.yaml");
        write(skill_dir.join("codex").join("body.md"), "codex body").expect("write codex body.md");

        let loaded = load_skill_definition(skill_dir).expect("load skill");
        let codex = loaded.codex.expect("codex variant");
        assert_eq!(loaded.source.description, "base");
        assert_eq!(loaded.body, "base body");
        assert_eq!(codex.source.description, "codex");
        assert_eq!(codex.body, "codex body");
    }
}

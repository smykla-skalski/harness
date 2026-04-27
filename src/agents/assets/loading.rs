use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, validate_safe_segment};

use super::files::io_err;
use super::model::{
    PLUGINS_ROOT, PluginDefinition, PluginSource, SKILLS_ROOT, SkillDefinition, SkillSource,
    SkillVariant,
};

enum SkillDirectoryKind {
    SkillDefinition,
    NonSkill,
}

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
        let skill_root = entry.path();
        if let SkillDirectoryKind::SkillDefinition = classify_skill_directory(&skill_root)? {
            skills.push(load_skill_definition(skill_root)?);
        }
    }
    skills.sort_by(|a, b| a.source.name.cmp(&b.source.name));
    Ok(skills)
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
                let skill_root = skill_dir.path();
                if let SkillDirectoryKind::SkillDefinition = classify_skill_directory(&skill_root)? {
                    skills.push(load_skill_definition(skill_root)?);
                }
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

fn classify_skill_directory(root: &Path) -> Result<SkillDirectoryKind, CliError> {
    let has_skill_yaml = root.join("skill.yaml").is_file();
    let has_body_md = root.join("body.md").is_file();
    match (has_skill_yaml, has_body_md) {
        (true, true) => Ok(SkillDirectoryKind::SkillDefinition),
        (false, false) => Ok(SkillDirectoryKind::NonSkill),
        (true, false) => Err(CliErrorKind::usage_error(format!(
            "malformed skill directory `{}`: found skill.yaml but missing body.md",
            root.display()
        ))
        .into()),
        (false, true) => Err(CliErrorKind::usage_error(format!(
            "malformed skill directory `{}`: found body.md but missing skill.yaml",
            root.display()
        ))
        .into()),
    }
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
    use std::fs::{self, create_dir_all};
    use std::path::Path;

    use tempfile::TempDir;

    use super::{SKILLS_ROOT, load_plugin_sources, load_skill_definition, load_skill_sources};

    fn write(path: &Path, content: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent directories");
        }
        fs::write(path, content).expect("write file");
    }

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
            &skill_dir.join("skill.yaml"),
            "name: real-skill\ndescription: ok\n",
        );
        write(&skill_dir.join("body.md"), "body");

        // Sibling workspace directory created by skill-creator iterations.
        // It carries no `skill.yaml` and the loader must not try to read one.
        let workspace = skills_root.join("real-skill-workspace");
        create_dir_all(workspace.join("iteration-1")).expect("create workspace dir");
        write(&workspace.join("iteration-1").join("notes.md"), "scratch");

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
            &plugin_root.join("plugin.yaml"),
            "name: demo\ndescription: demo plugin\nversion: 0.1.0\n",
        );
        write(
            &plugin_root.join("skills").join("real").join("skill.yaml"),
            "name: real\ndescription: ok\n",
        );
        write(&plugin_root.join("skills").join("real").join("body.md"), "body");

        // Sibling workspace inside the plugin's `skills/` directory.
        let workspace = plugin_root.join("skills").join("real-workspace");
        create_dir_all(workspace.join("iteration-1")).expect("create plugin workspace");
        write(&workspace.join("iteration-1").join("scratch.md"), "scratch");

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
            &skill_dir.join("skill.yaml"),
            "name: real-skill\ndescription: base\nallowed-tools: Bash\n",
        );
        write(&skill_dir.join("body.md"), "base body");
        write(
            &skill_dir.join("codex").join("skill.yaml"),
            "name: real-skill\ndescription: codex\n",
        );
        write(&skill_dir.join("codex").join("body.md"), "codex body");

        let loaded = load_skill_definition(skill_dir).expect("load skill");
        let codex = loaded.codex.expect("codex variant");
        assert_eq!(loaded.source.description, "base");
        assert_eq!(loaded.body, "base body");
        assert_eq!(codex.source.description, "codex");
        assert_eq!(codex.body, "codex body");
    }

    #[test]
    fn load_skill_sources_ignores_directories_without_skill_files() {
        let tmp = TempDir::new().expect("tempdir");
        let shared_root = tmp.path().join("agents/skills");
        write(
            &shared_root.join("council/skill.yaml"),
            "name: council\ndescription: Council skill\n",
        );
        write(
            &shared_root.join("council/body.md"),
            "# Council\n\nCanonical skill body.\n",
        );
        write(
            &shared_root.join("workspace/notes.md"),
            "# Scratch workspace.\n",
        );

        let skills = load_skill_sources(tmp.path()).expect("shared skill discovery succeeds");

        assert_eq!(skills.len(), 1);
        assert_eq!(skills[0].source.name, "council");
    }

    #[test]
    fn load_skill_sources_errors_when_body_is_missing_from_skill_directory() {
        let tmp = TempDir::new().expect("tempdir");
        let shared_root = tmp.path().join("agents/skills");
        write(
            &shared_root.join("council/skill.yaml"),
            "name: council\ndescription: Council skill\n",
        );

        let error =
            load_skill_sources(tmp.path()).expect_err("partial shared skill should be rejected");

        let rendered = format!("{error:#}");
        assert!(rendered.contains("malformed skill directory"));
        assert!(rendered.contains("missing body.md"));
        assert!(rendered.contains("agents/skills/council"));
    }

    #[test]
    fn load_skill_sources_errors_when_skill_yaml_is_missing_from_skill_directory() {
        let tmp = TempDir::new().expect("tempdir");
        let shared_root = tmp.path().join("agents/skills");
        write(
            &shared_root.join("council/body.md"),
            "# Council\n\nCanonical skill body.\n",
        );

        let error =
            load_skill_sources(tmp.path()).expect_err("partial shared skill should be rejected");

        let rendered = format!("{error:#}");
        assert!(rendered.contains("malformed skill directory"));
        assert!(rendered.contains("missing skill.yaml"));
        assert!(rendered.contains("agents/skills/council"));
    }

    #[test]
    fn load_plugin_sources_ignores_plugin_skill_directories_without_skill_files() {
        let tmp = TempDir::new().expect("tempdir");
        let plugin_root = tmp.path().join("agents/plugins/council");
        write(
            &plugin_root.join("plugin.yaml"),
            "name: council\ndescription: Council plugin\nversion: 1.0.0\n",
        );
        write(
            &plugin_root.join("skills/council/skill.yaml"),
            "name: council\ndescription: Council skill\n",
        );
        write(
            &plugin_root.join("skills/council/body.md"),
            "# Council\n\nCanonical skill body.\n",
        );
        write(
            &plugin_root.join("skills/council-workspace/evals.md"),
            "# Workspace artifacts live here.\n",
        );

        let plugins = load_plugin_sources(tmp.path(), &[]).expect("plugin discovery succeeds");

        assert_eq!(plugins.len(), 1);
        assert_eq!(plugins[0].source.name, "council");
        assert_eq!(plugins[0].skills.len(), 1);
        assert_eq!(plugins[0].skills[0].source.name, "council");
    }

    #[test]
    fn load_plugin_sources_errors_when_plugin_skill_directory_is_missing_body() {
        let tmp = TempDir::new().expect("tempdir");
        let plugin_root = tmp.path().join("agents/plugins/council");
        write(
            &plugin_root.join("plugin.yaml"),
            "name: council\ndescription: Council plugin\nversion: 1.0.0\n",
        );
        write(
            &plugin_root.join("skills/council/skill.yaml"),
            "name: council\ndescription: Council skill\n",
        );

        let error = load_plugin_sources(tmp.path(), &[])
            .expect_err("partial plugin skill directory should be rejected");

        let rendered = format!("{error:#}");
        assert!(rendered.contains("malformed skill directory"));
        assert!(rendered.contains("missing body.md"));
        assert!(rendered.contains("agents/plugins/council/skills/council"));
    }

    #[test]
    fn load_plugin_sources_errors_when_plugin_skill_directory_is_missing_skill_yaml() {
        let tmp = TempDir::new().expect("tempdir");
        let plugin_root = tmp.path().join("agents/plugins/council");
        write(
            &plugin_root.join("plugin.yaml"),
            "name: council\ndescription: Council plugin\nversion: 1.0.0\n",
        );
        write(
            &plugin_root.join("skills/council/body.md"),
            "# Council\n\nCanonical skill body.\n",
        );

        let error = load_plugin_sources(tmp.path(), &[])
            .expect_err("partial plugin skill directory should be rejected");

        let rendered = format!("{error:#}");
        assert!(rendered.contains("malformed skill directory"));
        assert!(rendered.contains("missing skill.yaml"));
        assert!(rendered.contains("agents/plugins/council/skills/council"));
    }
}

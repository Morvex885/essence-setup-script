//! Template store and `template *` commands (v1 `templates.sh` and the
//! template handlers of `cmd_clients.sh`). Built-in templates are embedded in
//! the binary; a custom file `<state>/templates/<name>.yaml` shadows the
//! built-in of the same name. Nothing outside the state directory is read or
//! written: files of `template import`/`export` are the client's business.

use std::fs;
use std::io::{ErrorKind, Write};
use std::path::PathBuf;

use include_dir::{Dir, include_dir};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::Config;
use crate::nodes::required;
use crate::request_input::Input;
use crate::secure_fs;
use crate::state::{State, read_optional};
use crate::validation as v;

/// Built-in templates live in the crate (`remote-control/core/templates/*.yaml`).
static BUILTIN: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/templates");

/// The template of a group without an explicit assignment.
pub const DEFAULT: &str = "default.yaml";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateSource { Builtin, Custom }

impl TemplateSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Builtin => "builtin",
            Self::Custom => "custom",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Template {
    pub name: String,
    pub source: TemplateSource,
    pub content: String,
}

/// Template file name: the `.yaml` suffix is optional on input.
pub fn file_name(raw: &str) -> String {
    if raw.ends_with(".yaml") { raw.to_owned() } else { format!("{raw}.yaml") }
}

/// Content of an embedded built-in template.
pub fn builtin(name: &str) -> Option<&'static str> {
    if !v::template_filename_valid(name) { return None; }
    BUILTIN.get_file(name).and_then(|file| file.contents_utf8())
}

fn builtin_names() -> impl Iterator<Item = &'static str> {
    BUILTIN.files().filter_map(|file| file.path().to_str()).filter(|name| v::template_filename_valid(name))
}

fn custom_path(state: &State, name: &str) -> PathBuf {
    state.paths().templates().join(name)
}

/// A custom template file: absent → None; anything but a regular UTF-8 file
/// (symlink, directory) is refused rather than followed.
fn read_custom(state: &State, name: &str) -> Result<Option<String>> {
    let path = custom_path(state, name);
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_file() => {}
        Ok(_) => return Err(RcError::new("unsafe_path", format!("Недопустимый тип пути шаблона: {}", path.display()))),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    let bytes = read_optional(&path)?.unwrap_or_default();
    String::from_utf8(bytes.to_vec()).map(Some)
        .map_err(|_| RcError::new("invalid", format!("Шаблон «{name}» не в кодировке UTF-8.")))
}

fn custom_exists(state: &State, name: &str) -> Result<bool> {
    match fs::symlink_metadata(custom_path(state, name)) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

/// Resolve a template file name: the custom file wins over the built-in.
/// An invalid file name resolves to nothing.
pub fn resolve(state: &State, name: &str) -> Result<Option<Template>> {
    if !v::template_filename_valid(name) { return Ok(None); }
    if let Some(content) = read_custom(state, name)? {
        return Ok(Some(Template { name: name.to_owned(), source: TemplateSource::Custom, content }));
    }
    Ok(builtin(name).map(|content| Template { name: name.to_owned(), source: TemplateSource::Builtin, content: content.to_owned() }))
}

pub fn not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Шаблон «{name}» не найден.")).with_extra("name", name)
}

pub fn require(state: &State, name: &str) -> Result<Template> {
    resolve(state, name)?.ok_or_else(|| not_found(name))
}

/// Custom and built-in template names without duplicates, sorted; the
/// source is `custom` when a custom file exists.
pub fn list(state: &State) -> Result<Vec<(String, TemplateSource)>> {
    let mut names: Vec<(String, TemplateSource)> = Vec::new();
    match fs::read_dir(state.paths().templates()) {
        Ok(entries) => for entry in entries {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if v::template_filename_valid(&name) && entry.file_type()?.is_file() {
                names.push((name, TemplateSource::Custom));
            }
        },
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    for name in builtin_names() {
        if !names.iter().any(|(known, _)| known == name) {
            names.push((name.to_owned(), TemplateSource::Builtin));
        }
    }
    names.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(names)
}

/// Template file name assigned to a group (`default.yaml` without one).
pub fn group_template(config: &Config, group: &str) -> String {
    config.groups.iter().find(|g| g.name == group).map(|g| g.template.as_str())
        .filter(|template| !template.is_empty()).unwrap_or(DEFAULT).to_owned()
}

/// v1 `process_template`: `# --- TAG ---` / `# --- A/B ---` blocks are kept
/// (without markers) for a listed group and dropped otherwise. A marker with
/// a different tag inside a block is plain content. Every emitted line ends
/// with a newline; a CRLF marker is recognised like an LF one.
pub fn process(content: &str, group: &str) -> String {
    let mut output = String::with_capacity(content.len());
    let mut block: Option<(&str, bool)> = None;
    for line in content.split_inclusive('\n') {
        let line = line.strip_suffix('\n').unwrap_or(line);
        if let Some(tag) = marker(line) {
            match block {
                None => {
                    block = Some((tag, !group.is_empty() && tag.split('/').any(|g| g == group)));
                    continue;
                }
                Some((open, _)) if open == tag => {
                    block = None;
                    continue;
                }
                Some(_) => {}
            }
        }
        if block.is_none_or(|(_, keep)| keep) {
            output.push_str(line);
            output.push('\n');
        }
    }
    output
}

fn marker(line: &str) -> Option<&str> {
    let line = line.strip_suffix('\r').unwrap_or(line);
    let tag = line.strip_prefix("# --- ")?.strip_suffix(" ---")?;
    (!tag.is_empty() && tag.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'/' || b == b'_'))
        .then_some(tag)
}

fn name_invalid() -> RcError {
    RcError::new("invalid", "Имя шаблона может содержать только буквы, цифры, точку, - и _")
}

/// `--name` of create/import: the base name (optional `.yaml`) as a file name.
fn new_file_name(raw: &str) -> Result<String> {
    let base = raw.strip_suffix(".yaml").unwrap_or(raw);
    if !v::template_name_valid(base) { return Err(name_invalid()); }
    Ok(format!("{base}.yaml"))
}

fn optional_value<'a>(invocation: &'a Invocation, flag: &str) -> Result<Option<&'a str>> {
    if invocation.has(flag) { required(invocation, flag).map(Some) } else { Ok(None) }
}

/// Groups that use the template.
fn groups_using(config: &Config, name: &str) -> Vec<String> {
    config.groups.iter().filter(|g| group_template(config, &g.name) == name).map(|g| g.name.clone()).collect()
}

pub fn list_command(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    Ok(Value::Array(list(&session.state)?.into_iter().map(|(name, source)| json!({
        "name": name, "source": source.as_str(), "groups": groups_using(&config, &name),
    })).collect()))
}

pub fn show(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = file_name(required(invocation, "name")?);
    let template = require(&session.state, &name)?;
    let path = (template.source == TemplateSource::Custom)
        .then(|| custom_path(&session.state, &name).display().to_string());
    Ok(json!({"name": name, "source": template.source.as_str(), "path": path, "content": template.content}))
}

pub fn create(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let raw = required(invocation, "name")?;
    let from = optional_value(invocation, "from")?.map(file_name);
    let group = optional_value(invocation, "group")?.map(str::to_owned);
    if let Some(group) = &group {
        super::find_group(&session.state.load_config()?, group)?;
    }
    let name = new_file_name(raw)?;
    let base = from.unwrap_or_else(|| DEFAULT.to_owned());
    let data = session.mutate("template_create", |state| {
        if custom_exists(state, &name)? {
            return Err(RcError::new("conflict", format!("Шаблон «{name}» уже существует.")).with_extra("name", name.clone()));
        }
        let content = require(state, &base)?.content;
        let mut config = state.load_config()?;
        if let Some(group) = &group {
            super::find_group(&config, group)?;
            config.groups.iter_mut().filter(|g| &g.name == group).for_each(|g| g.template = name.clone());
        }
        secure_fs::create_dir_all(state.paths().templates())?;
        let path = custom_path(state, &name);
        let written = secure_fs::create_new(&path).and_then(|mut file| {
            file.write_all(content.as_bytes())?;
            file.sync_all()
        });
        if let Err(error) = written {
            let _ = fs::remove_file(&path);
            return Err(RcError::new("failed", format!("Не удалось создать шаблон {name}: {error}")));
        }
        if group.is_some() && let Err(error) = state.save_config(&config) {
            let _ = fs::remove_file(&path);
            return Err(error);
        }
        Ok(json!({"name": name, "based_on": base, "group": group}))
    })?;
    session.log(Level::Success, &format!("Шаблон {name} создан"));
    Ok(data)
}

/// The template text arrives as request input `file`; the client read the
/// file (or the editor buffer). The overwrite token covers the content: the
/// path never reaches the daemon, so a token issued for one file must not
/// consent to another.
pub fn import(session: &mut Session, invocation: &Invocation, input: &Input) -> Result<Value> {
    let name = new_file_name(required(invocation, "name")?)?;
    let content = input.get("file").ok_or_else(|| RcError::new("usage", "Передайте содержимое полем input.file."))?;
    if custom_exists(&session.state, &name)? {
        let digest = hex::encode(Sha256::digest(content.as_bytes()));
        Plan::new(vec![format!("Шаблон {name} будет перезаписан.")], digest).confirm(invocation)?;
    }
    session.mutate("template_import", |state| {
        secure_fs::create_dir_all(state.paths().templates())?;
        secure_fs::atomic_write(&custom_path(state, &name), content.as_bytes())
            .map_err(|_| RcError::new("failed", format!("Не удалось сохранить шаблон {name}.")))
    })?;
    session.log(Level::Success, &format!("Шаблон {name} импортирован"));
    Ok(json!({"name": name}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nodes::testing::{fingerprint, invocation, session};

    fn run(session: &mut Session, argv: &[&str]) -> Result<Value> {
        let invocation = invocation(argv);
        match invocation.verb.as_str() {
            "list" => list_command(session),
            "show" => show(session, &invocation),
            _ => create(session, &invocation),
        }
    }

    fn import_text(session: &mut Session, argv: &[&str], content: Option<&str>) -> Result<Value> {
        let mut input = Input::default();
        if let Some(content) = content {
            input.insert("file", content.to_owned().into()).unwrap();
        }
        import(session, &invocation(argv), &input)
    }

    fn custom(session: &Session, name: &str, content: &str) -> PathBuf {
        let dir = session.state.paths().templates();
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join(name), content).unwrap();
        dir.join(name)
    }

    #[test]
    fn process_filters_group_blocks_like_v1() {
        let cases: &[(&str, &str, &str)] = &[
            ("line1\nline2\nline3", "PC", "line1\nline2\nline3\n"),
            ("before\n# --- PC ---\nkept line\n# --- PC ---\nafter", "PC", "before\nkept line\nafter\n"),
            ("before\n# --- MOBILE ---\nhidden line\n# --- MOBILE ---\nafter", "PC", "before\nafter\n"),
            ("# --- ROUTER/PC ---\nkept\n# --- ROUTER/PC ---", "PC", "kept\n"),
            ("before\n# --- ROUTER/PC ---\nhidden\n# --- ROUTER/PC ---\nafter", "MOBILE", "before\nafter\n"),
            ("header\n# --- PC ---\npc content\n# --- PC ---\nmiddle\n# --- MOBILE ---\nmobile content\n# --- MOBILE ---\nfooter",
                "PC", "header\npc content\nmiddle\nfooter\n"),
            ("# --- ROUTER ---\nrouter line\n# --- ROUTER ---\n# --- PC ---\npc line\n# --- PC ---", "ROUTER", "router line\n"),
            ("# --- PC ---\nleaked content", "PC", "leaked content\n"),
            ("# --- MOBILE ---\nhidden content", "PC", ""),
            ("# --- lowercase ---\nvisible", "lowercase", "# --- lowercase ---\nvisible\n"),
            ("  # --- PC ---\nvisible", "PC", "  # --- PC ---\nvisible\n"),
            ("# --- PC ---\n# --- ROUTER ---\ninner content\n# --- ROUTER ---\n# --- PC ---\nafter", "PC",
                "# --- ROUTER ---\ninner content\n# --- ROUTER ---\nafter\n"),
            ("# --- MOBILE ---\n# --- PC ---\nhidden\n# --- PC ---\n# --- MOBILE ---\nafter", "PC", "after\n"),
            ("", "PC", ""),
            ("# --- PC ---\nx\n# --- PC ---\n", "", ""),
            // A CRLF template filters like an LF one; content lines keep their CR.
            ("a\r\n# --- MOBILE ---\r\nm\r\n# --- MOBILE ---\r\nb\r\n", "PC", "a\r\nb\r\n"),
        ];
        for (input, group, expected) in cases {
            assert_eq!(process(input, group), *expected, "{input:?} for {group}");
        }
        let default = builtin(DEFAULT).unwrap();
        let router = process(default, "ROUTER");
        assert!(router.lines().any(|l| l == "redir-port: 1182") && !router.lines().any(|l| l == "  stack: mixed"));
        assert!(!router.contains("# --- ROUTER ---"));
        let pc = process(default, "PC");
        assert!(!pc.lines().any(|l| l == "redir-port: 1182") && pc.lines().any(|l| l == "  stack: mixed"));
        assert!(pc.contains("# --- НАСТРОЙКИ GEO-ДАННЫХ ---"));
    }

    #[test]
    fn store_resolves_custom_over_builtin_and_refuses_unsafe_entries() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = session(root.path());
        let state = &session.state;
        assert_eq!(list(state).unwrap(), [("default.yaml".to_owned(), TemplateSource::Builtin)]);
        let resolved = resolve(state, "default.yaml").unwrap().unwrap();
        assert_eq!((resolved.source, resolved.content.as_str()), (TemplateSource::Builtin, builtin(DEFAULT).unwrap()));
        for bad in ["../default.yaml", "default", "", "a/b.yaml", ".yaml"] {
            assert!(resolve(state, bad).unwrap().is_none(), "{bad}");
        }
        assert_eq!(require(state, "nope.yaml").unwrap_err().code, "not_found");
        custom(&session, "default.yaml", "mode: rule\n");
        custom(&session, "b.yaml", "b\n");
        custom(&session, "notes.txt", "x");
        assert_eq!(resolve(state, "default.yaml").unwrap().unwrap(),
            Template { name: "default.yaml".into(), source: TemplateSource::Custom, content: "mode: rule\n".into() });
        assert_eq!(list(state).unwrap(), [("b.yaml".to_owned(), TemplateSource::Custom), ("default.yaml".to_owned(), TemplateSource::Custom)]);
        fs::write(state.paths().templates().join("bad.yaml"), [0xff, 0xfe]).unwrap();
        assert_eq!(resolve(state, "bad.yaml").unwrap_err().code, "invalid");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.path().join("config.json"), state.paths().templates().join("link.yaml")).unwrap();
            assert_eq!(resolve(state, "link.yaml").unwrap_err().code, "unsafe_path");
            assert!(list(state).unwrap().iter().all(|(name, _)| name != "link.yaml"));
        }
        assert_eq!(file_name("x"), "x.yaml");
        assert_eq!(file_name("x.yaml"), "x.yaml");
    }

    #[test]
    fn list_and_show_report_source_groups_and_path() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let path = custom(&session, "alt.yaml", "mode: rule\n");
        let mut config = session.state.load_config().unwrap();
        config.groups[1].template = "alt.yaml".into();
        session.state.save_config(&config).unwrap();
        assert_eq!(run(&mut session, &["template", "list"]).unwrap(), json!([
            {"name": "alt.yaml", "source": "custom", "groups": ["PC"]},
            {"name": "default.yaml", "source": "builtin", "groups": ["ROUTER", "MOBILE"]},
        ]));
        assert_eq!(run(&mut session, &["template", "show", "--name", "alt"]).unwrap(), json!({
            "name": "alt.yaml", "source": "custom", "path": path.display().to_string(), "content": "mode: rule\n"}));
        let shown = run(&mut session, &["template", "show", "--name", "default.yaml"]).unwrap();
        assert_eq!((shown["source"].clone(), shown["path"].clone()), (json!("builtin"), Value::Null));
        assert_eq!(shown["content"], builtin(DEFAULT).unwrap());
        assert_eq!(run(&mut session, &["template", "show", "--name", "missing"]).unwrap_err().code, "not_found");
    }

    #[test]
    fn create_copies_a_base_assigns_the_group_and_validates_first() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let templates = session.state.paths().templates().to_path_buf();
        assert_eq!(run(&mut session, &["template", "create", "--name", "blank"]).unwrap(),
            json!({"name": "blank.yaml", "based_on": "default.yaml", "group": null}));
        assert_eq!(fs::read_to_string(templates.join("blank.yaml")).unwrap(), builtin(DEFAULT).unwrap());
        custom(&session, "default.yaml", "mode: rule\n");
        assert_eq!(run(&mut session, &["template", "create", "--name", "lab.v2", "--group", "PC"]).unwrap(),
            json!({"name": "lab.v2.yaml", "based_on": "default.yaml", "group": "PC"}));
        assert_eq!(fs::read_to_string(templates.join("lab.v2.yaml")).unwrap(), "mode: rule\n");
        let config = session.state.load_config().unwrap();
        assert_eq!((config.groups[0].template.as_str(), config.groups[1].template.as_str()), ("default.yaml", "lab.v2.yaml"));
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, &["template", "create", "--name", "copy", "--from", "lab.v2"]).unwrap(),
            json!({"name": "copy.yaml", "based_on": "lab.v2.yaml", "group": null}));
        assert_eq!(session.state.load_config().unwrap(), config);
        fs::remove_file(templates.join("copy.yaml")).unwrap();
        assert_eq!(fingerprint(root.path()).remove("config.json"), before.clone().remove("config.json"));
        for (argv, code) in [
            (&["template", "create", "--name", "bad name"][..], "invalid"),
            (&["template", "create", "--name", "../up"], "invalid"),
            (&["template", "create", "--name", "default"], "conflict"),
            (&["template", "create", "--name", "new", "--from", "nope"], "not_found"),
            (&["template", "create", "--name", "new", "--from", "../config.json"], "not_found"),
            (&["template", "create", "--name", "new", "--group", "NOPE"], "not_found"),
            (&["template", "create", "--name", "new", "--from", ""], "usage"),
        ] {
            assert_eq!(run(&mut session, argv).unwrap_err().code, code, "{argv:?}");
        }
        assert!(!templates.join("new.yaml").exists());
        let mut after = fingerprint(root.path());
        after.remove("manifest.json");
        let mut expected = before;
        expected.remove("manifest.json");
        assert_eq!(after, expected);
    }

    #[test]
    fn import_takes_the_input_validates_the_name_and_gates_overwrites() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = session(root.path());
        assert_eq!(import_text(&mut session, &["template", "import", "--name", "lab.yaml"], Some("mode: rule\n")).unwrap(),
            json!({"name": "lab.yaml"}));
        let stored = session.state.paths().templates().join("lab.yaml");
        assert_eq!(fs::read_to_string(&stored).unwrap(), "mode: rule\n");
        assert_eq!(journal.borrow().last().unwrap().1, "Шаблон lab.yaml импортирован");
        let before = fingerprint(root.path());
        let error = import_text(&mut session, &["template", "import", "--name", "lab"], Some("mode: global\n")).unwrap_err();
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(error.extra["plan"], json!(["Шаблон lab.yaml будет перезаписан."]));
        for (argv, content, code) in [
            (&["template", "import", "--name", "../x"][..], Some("x"), "invalid"),
            (&["template", "import", "--name", "a b"], Some("x"), "invalid"),
            (&["template", "import"], Some("x"), "usage"),
            (&["template", "import", "--name", "new"], None, "usage"),
        ] {
            assert_eq!(import_text(&mut session, argv, content).unwrap_err().code, code, "{argv:?}");
        }
        let missing = import_text(&mut session, &["template", "import", "--name", "new"], None).unwrap_err();
        assert_eq!(missing.message, "Передайте содержимое полем input.file.");
        assert_eq!(fingerprint(root.path()), before);
        let other = import_text(&mut session, &["template", "import", "--name", "lab"], Some("mode: direct\n")).unwrap_err();
        let token = error.extra["plan_token"].as_str().unwrap();
        assert_ne!(other.extra["plan_token"], error.extra["plan_token"], "the token covers the content");
        let stale = import_text(&mut session, &["template", "import", "--name", "lab", "--yes", "--plan-token", token],
            Some("mode: direct\n")).unwrap_err();
        assert_eq!(stale.code, "plan_changed");
        assert_eq!(fingerprint(root.path()), before);
        import_text(&mut session, &["template", "import", "--name", "lab", "--yes", "--plan-token", token],
            Some("mode: global\n")).unwrap();
        assert_eq!(fs::read_to_string(&stored).unwrap(), "mode: global\n");
        import_text(&mut session, &["template", "import", "--name", "lab", "--yes"], Some("mode: rule\n")).unwrap();
        assert_eq!(fs::read_to_string(&stored).unwrap(), "mode: rule\n");
    }
}

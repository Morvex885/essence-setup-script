//! `group *` commands (v1 `groups.sh`).

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Config, Group};
use crate::nodes::required;
use crate::validation as v;

use super::{find_group, group_nodes, templates};

pub fn list(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    Ok(Value::Array(config.groups.iter().map(|group| json!({
        "name": group.name,
        "template": templates::group_template(&config, &group.name),
        "clients": config.clients.iter().filter(|c| c.group == group.name).count(),
        "nodes": group_nodes(&config, &group.name),
    })).collect()))
}

/// The name is stored upper-cased; it becomes a directory of generated
/// configs. `--template T` (`.yaml` optional) assigns an existing template in
/// the same change; without it the group uses `default.yaml`.
pub fn add(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_ascii_uppercase();
    if !v::name_valid(&name) {
        return Err(RcError::new("invalid", "Название группы может содержать только буквы, цифры, точку, - и _"));
    }
    let template = if invocation.has("template") {
        let template = templates::file_name(required(invocation, "template")?);
        if !v::template_filename_valid(&template) { return Err(templates::name_invalid()); }
        Some(template)
    } else {
        None
    };
    let template = session.mutate("add_group", |state| {
        let mut config = state.load_config()?;
        if config.groups.iter().any(|g| g.name == name) {
            return Err(RcError::new("conflict", format!("Группа «{name}» уже существует.")).with_extra("name", name.clone()));
        }
        let mut group = Group { name: name.clone(), ..Group::default() };
        if let Some(template) = &template {
            templates::require(state, template)?;
            group.template = template.clone();
        }
        config.groups.push(group);
        state.save_config(&config)?;
        Ok(templates::group_template(&config, &name))
    })?;
    session.log(Level::Success, &format!("Группа «{name}» добавлена (шаблон «{template}»)"));
    Ok(json!({"name": name, "template": template}))
}

fn delete_check(config: &Config, name: &str) -> Result<()> {
    find_group(config, name)?;
    if config.clients.iter().any(|c| c.group == name) {
        return Err(RcError::new("conflict", format!("В группе «{name}» есть клиенты. Сначала удалите их.")).with_extra("name", name));
    }
    Ok(())
}

/// Removes the group and its connection assignments; nodes left without any
/// group assignment lose their connection entry.
pub fn delete(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    delete_check(&session.state.load_config()?, &name)?;
    Plan::new(vec![format!("Группа: {name}"), "Назначения подключений этой группе будут удалены.".into()], "")
        .confirm(invocation)?;
    session.mutate("delete_group", |state| {
        let mut config = state.load_config()?;
        delete_check(&config, &name)?;
        config.groups.retain(|g| g.name != name);
        for connection in &mut config.connections {
            connection.groups.retain(|g| g.name != name);
        }
        config.connections.retain(|c| !c.groups.is_empty());
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Группа {name} удалена"));
    Ok(json!({"name": name}))
}

/// The `.yaml` suffix of the template is optional.
pub fn set_template(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let template = templates::file_name(required(invocation, "template")?);
    session.mutate("assign_template", |state| {
        let mut config = state.load_config()?;
        find_group(&config, &name)?;
        templates::require(state, &template)?;
        config.groups.iter_mut().filter(|g| g.name == name).for_each(|g| g.template = template.clone());
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Группа {name}: шаблон — {template}"));
    Ok(json!({"name": name, "template": template}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::testing::config;
    use crate::model::ConnectionGroup;
    use crate::nodes::testing::{fingerprint, invocation, session};

    fn run(session: &mut Session, argv: &[&str]) -> Result<Value> {
        let invocation = invocation(argv);
        match invocation.verb.as_str() {
            "list" => list(session),
            "add" => add(session, &invocation),
            "delete" => delete(session, &invocation),
            _ => set_template(session, &invocation),
        }
    }

    #[test]
    fn add_upper_cases_and_rejects_unsafe_duplicate_or_missing_names() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        assert_eq!(run(&mut session, &["group", "add", "--name", "lab"]).unwrap(), json!({"name": "LAB", "template": "default.yaml"}));
        let config = session.state.load_config().unwrap();
        assert!(config.groups.iter().any(|g| g.name == "LAB" && g.template == "default.yaml"));
        let before = fingerprint(root.path());
        for name in ["..", "../../..", "A/B", "...", "A B"] {
            assert_eq!(run(&mut session, &["group", "add", "--name", name]).unwrap_err().code, "invalid", "{name}");
        }
        assert_eq!(run(&mut session, &["group", "add", "--name", "LAB"]).unwrap_err().code, "conflict");
        let error = run(&mut session, &["group", "add"]).unwrap_err();
        assert_eq!((error.code, error.exit), ("usage", 2));
        assert_eq!(fingerprint(root.path()), before);
        // A template in the same change: checked first, nothing is added without it.
        for (template, code) in [("ghost", "not_found"), ("../x", "invalid"), ("", "usage")] {
            let error = run(&mut session, &["group", "add", "--name", "pc2", "--template", template]).unwrap_err();
            assert_eq!(error.code, code, "{template:?}");
        }
        assert_eq!(fingerprint(root.path()), before);
        std::fs::create_dir_all(session.state.paths().templates()).unwrap();
        std::fs::write(session.state.paths().templates().join("lab.yaml"), "proxies:\n").unwrap();
        assert_eq!(run(&mut session, &["group", "add", "--name", "pc2", "--template", "lab"]).unwrap(),
            json!({"name": "PC2", "template": "lab.yaml"}));
        assert!(session.state.load_config().unwrap().groups.iter().any(|g| g.name == "PC2" && g.template == "lab.yaml"));
    }

    #[test]
    fn delete_is_gated_refuses_groups_with_clients_and_drops_assignments() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let mut config = config();
        config.groups.push(Group { name: "EMPTY".into(), ..Group::default() });
        config.connections[0].groups.push(ConnectionGroup { name: "EMPTY".into(), proxies: vec!["keep-proxy".into()] });
        config.connections.push(crate::model::Connection { node: "ru-vps".into(), groups: vec![] });
        config.connections.push(crate::model::Connection { node: "de-vps".into(), groups: vec![
            ConnectionGroup { name: "EMPTY".into(), proxies: vec!["only".into()] }] });
        session.state.save_config(&config).unwrap();
        let before = fingerprint(root.path());
        let error = run(&mut session, &["group", "delete", "--name", "EMPTY"]).unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!(["Группа: EMPTY", "Назначения подключений этой группе будут удалены."]));
        assert_eq!(fingerprint(root.path()), before);
        let error = run(&mut session, &["group", "delete", "--name", "ROUTER", "--yes"]).unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(run(&mut session, &["group", "delete", "--name", "NOPE", "--yes"]).unwrap_err().code, "not_found");
        assert_eq!(fingerprint(root.path()), before);
        assert_eq!(run(&mut session, &["group", "delete", "--name", "EMPTY", "--yes"]).unwrap(), json!({"name": "EMPTY"}));
        let after = session.state.load_config().unwrap();
        assert!(after.groups.iter().all(|g| g.name != "EMPTY"));
        assert!(after.connections.iter().all(|c| !c.groups.is_empty() && c.groups.iter().all(|g| g.name != "EMPTY")));
        assert_eq!(after.connections.len(), 2);
        assert_eq!(after.connections[0].groups[0].name, "PC");
    }

    #[test]
    fn set_template_accepts_custom_and_builtin_and_rejects_unknown() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        std::fs::create_dir_all(session.state.paths().templates()).unwrap();
        std::fs::write(session.state.paths().templates().join("alternate.yaml"), "mode: rule\n").unwrap();
        assert_eq!(run(&mut session, &["group", "set-template", "--name", "ROUTER", "--template", "alternate"]).unwrap(),
            json!({"name": "ROUTER", "template": "alternate.yaml"}));
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, &["group", "set-template", "--name", "ROUTER", "--template", "missing"]).unwrap_err().code, "not_found");
        assert_eq!(run(&mut session, &["group", "set-template", "--name", "ROUTER", "--template", "../x"]).unwrap_err().code, "not_found");
        assert_eq!(run(&mut session, &["group", "set-template", "--name", "NOPE", "--template", "default"]).unwrap_err().code, "not_found");
        assert_eq!(fingerprint(root.path()), before);
        run(&mut session, &["group", "set-template", "--name", "ROUTER", "--template", "default.yaml"]).unwrap();
        let listed = run(&mut session, &["group", "list"]).unwrap();
        assert_eq!(listed[0], json!({"name": "ROUTER", "template": "default.yaml", "clients": 0, "nodes": []}));
    }
}

use serde::Serialize;

use crate::{
    error::Result,
    model::Auth,
    state::State,
    VERSION,
};

#[derive(Debug, Serialize)]
pub struct Status {
    pub version: &'static str,
    pub update: Update,
    pub script_password: bool,
    pub source: SourceSummary,
    pub counts: Counts,
    pub password_missing: Vec<String>,
    pub ssh_setup_pending: bool,
    pub subscription_host: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Update {
    pub current: &'static str,
    pub latest: Option<String>,
    pub available: bool,
}

#[derive(Debug, Serialize)]
pub struct SourceSummary {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub repo: Option<String>,
    pub sync: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Counts {
    pub nodes: usize,
    pub groups: usize,
    pub clients: usize,
}

/// Read a local snapshot without creating files, opening a session or networking.
/// Authentication is the caller's responsibility; the CLI gates protected state.
/// `sync` is the open GitHub session's status (`None` for local).
pub fn status(state: &State, sync: Option<&str>) -> Result<Status> {
    let config = state.load_config()?;
    let manifest = state.load_manifest()?;
    let source = state.load_source()?;
    let secrets = state.secret_store();
    let mut password_missing = Vec::new();
    secrets.validate()?;
    for node in &config.nodes {
        if node.auth == Auth::Password {
            let available = match node.secret_id.as_deref() {
                Some(id) => match secrets.get(id) {
                    Ok(value) => value.is_some(),
                    Err(error) if error.code == "missing_secret" => false,
                    Err(error) => return Err(error),
                },
                None => false,
            };
            if !available {
                password_missing.push(node.name.clone());
            }
        }
    }
    let github = source.is_some();
    Ok(Status {
        version: VERSION,
        update: Update { current: VERSION, latest: None, available: false },
        script_password: state.auth_store().is_configured()?,
        source: SourceSummary {
            kind: if github { "github" } else { "local" },
            repo: source.map(|metadata| metadata.repo),
            sync: sync.map(str::to_owned),
        },
        counts: Counts {
            nodes: config.nodes.len(), groups: config.groups.len(), clients: config.clients.len(),
        },
        password_missing,
        ssh_setup_pending: github && manifest.has_actionable_ssh_issues(),
        subscription_host: config.subscription_host.map(|host| host.node),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{secure_fs, state::StatePaths};
    use zeroize::Zeroizing;

    #[test]
    fn status_reports_missing_passwords_without_exposing_them() {
        let directory = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(directory.path().join("state"));
        let state = State::new(paths.clone());
        let mut config = state.load_config().unwrap();
        let id = "a".repeat(32);
        let secret_id = format!("node:{id}:ssh-password");
        config.nodes.push(serde_json::from_value(serde_json::json!({
            "id":id, "name":"test-node", "ip":"localhost", "port":2222, "user":"root",
            "auth":"password", "identity":null, "secret_id":secret_id,
            "tag":"test", "aliases":{}
        })).unwrap());
        state.save_config(&config).unwrap();
        let before = status(&state, None).unwrap();
        assert_eq!(before.counts.nodes, 1);
        assert_eq!(before.password_missing, ["test-node"]);
        let store = state.secret_store();
        store.set(&secret_id, Zeroizing::new("do-not-display-me".into())).unwrap();
        let after = status(&state, None).unwrap();
        assert!(after.password_missing.is_empty());
        let output = serde_json::to_string(&after).unwrap();
        assert!(!output.contains("do-not-display-me"));
        assert!(!output.contains(&secret_id));
    }

    #[test]
    fn malformed_secret_container_fails_even_without_password_nodes() {
        let directory = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(directory.path());
        secure_fs::atomic_write(&paths.secrets(), b"{\"schema_version\":1,\"node_passwords\":[]}").unwrap();
        let error = status(&State::new(paths), None).unwrap_err();
        assert_eq!(error.code, "invalid");
    }
}

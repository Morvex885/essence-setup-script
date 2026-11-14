//! The embedded node executor (`node-agent/` plus the two `common/` libraries
//! it sources). On the node it lives in `/root/essence-node/agent/<AGENT_SHA>/`
//! next to its `MANIFEST` (`sha256sum` format), so another RC version simply
//! uses another directory and a damaged copy fails `sha256sum -c`.

use std::sync::LazyLock;

use include_dir::{Dir, include_dir};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

use crate::bundle::{COMMON, write_file};
use crate::error::Result;

static AGENT: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../../node-agent");

/// Libraries of `common/` the executor sources.
const COMMON_FILES: [&str; 2] = ["common.sh", "cert.sh"];

/// Root of everything RC keeps on a node.
pub const NODE_ROOT: &str = "/root/essence-node";

/// `(relative path, contents)` of every executor file, sorted by path.
fn files() -> Vec<(String, &'static [u8])> {
    fn walk(dir: &'static Dir<'static>, out: &mut Vec<(String, &'static [u8])>) {
        for file in dir.files() {
            out.push((file.path().to_string_lossy().replace('\\', "/"), file.contents()));
        }
        for child in dir.dirs() {
            walk(child, out);
        }
    }
    let mut out = Vec::new();
    walk(&AGENT, &mut out);
    for name in COMMON_FILES {
        let file = COMMON.get_file(name).expect("embedded common library");
        out.push((format!("common/{name}"), file.contents()));
    }
    out.sort();
    out
}

/// `<sha256>  <path>` lines, sorted, newline-terminated.
static MANIFEST: LazyLock<String> = LazyLock::new(|| {
    let mut lines: Vec<String> = files().into_iter()
        .map(|(path, contents)| format!("{}  {path}", hex::encode(Sha256::digest(contents)))).collect();
    lines.sort();
    lines.into_iter().map(|line| line + "\n").collect()
});

static SHA: LazyLock<String> = LazyLock::new(|| hex::encode(Sha256::digest(MANIFEST.as_bytes())));

fn manifest() -> &'static str {
    &MANIFEST
}

/// Hex SHA-256 of the manifest: the executor's identity.
pub fn agent_sha() -> &'static str {
    &SHA
}

/// The executor directory on the node.
pub fn agent_dir() -> String {
    format!("{NODE_ROOT}/agent/{}", agent_sha())
}

/// A private temporary tree with the executor files and `MANIFEST`.
pub fn materialize_agent() -> Result<TempDir> {
    let directory = tempfile::Builder::new().prefix("essence-agent-").tempdir()?;
    crate::secure_fs::create_dir_all(directory.path())?;
    for (path, contents) in files() {
        let target = directory.path().join(&path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        write_file(&target, contents)?;
    }
    write_file(&directory.path().join("MANIFEST"), manifest().as_bytes())?;
    Ok(directory)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_lists_every_executor_file_and_names_the_directory() {
        let manifest = manifest();
        let paths: Vec<&str> = manifest.lines().map(|line| line.split_once("  ").unwrap().1).collect();
        for expected in ["apply.sh", "steps/base.sh", "common/common.sh", "common/cert.sh"] {
            assert!(paths.contains(&expected), "{expected} in {paths:?}");
        }
        assert!(manifest.lines().all(|line| line.len() > 66 && line.as_bytes()[64..66] == *b"  "));
        assert_eq!(agent_sha().len(), 64);
        assert_eq!(agent_dir(), format!("/root/essence-node/agent/{}", agent_sha()));

        let dir = materialize_agent().unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("MANIFEST")).unwrap(), manifest);
        for path in paths {
            let bytes = std::fs::read(dir.path().join(path)).unwrap();
            assert!(manifest.contains(&format!("{}  {path}\n", hex::encode(Sha256::digest(&bytes)))));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.path().join("apply.sh")).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
        }
    }
}

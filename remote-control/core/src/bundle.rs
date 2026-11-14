//! Embedded server scripts in the same flattened layout as `upload_scripts`.
//!
//! Only the setup entry, its modules, shared scripts and root VERSION are
//! materialized. Local state, templates and the standalone installer are not
//! deployment inputs. Remote publication (including VERSION-last replacement)
//! belongs to the transport.

use std::{fs, io, path::Path, time::Duration};

use include_dir::{Dir, include_dir};
use tempfile::TempDir;

use crate::{error::Result, transport::RemoteSession};

static SETUP: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../../setup-essence");
static COMMON: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../../common");
static VERSION: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../VERSION"));

/// Stateless, build-time snapshot of the server installation scripts.
#[derive(Clone, Copy, Debug, Default)]
pub struct ServerBundle;

impl ServerBundle {
    /// Extract a private, automatically removed directory ready for upload.
    ///
    /// Shell files have mode 0700 on Unix. Windows has no Unix executable bit;
    /// the SFTP transport must assign executable remote modes to `.sh` files
    /// independently of the materializing platform.
    pub fn materialize(&self) -> Result<TempDir> {
        let directory = tempfile::Builder::new().prefix("essence-server-").tempdir()?;
        crate::secure_fs::create_dir_all(directory.path())?;
        let entry = SETUP.get_file("setup-essence.sh").expect("embedded setup entry");
        write_file(&directory.path().join(entry.path()), entry.contents())?;
        extract_tree(SETUP.get_dir("modules").expect("embedded setup modules"), directory.path())?;
        extract_tree(&COMMON, &directory.path().join("common"))?;
        write_file(&directory.path().join("VERSION"), VERSION)?;
        Ok(directory)
    }

    /// Keep the materialized tree alive until the entire upload has completed.
    pub async fn upload<T: RemoteSession>(
        &self,
        transport: &T,
        remote_dir: &str,
        timeout: Duration,
    ) -> Result<()> {
        let directory = self.materialize()?;
        transport.upload(directory.path(), remote_dir, timeout).await
    }
}

pub(crate) fn extract_tree(directory: &Dir<'_>, root: &Path) -> io::Result<()> {
    fs::create_dir_all(root.join(directory.path()))?;
    for file in directory.files() {
        write_file(&root.join(file.path()), file.contents())?;
    }
    for child in directory.dirs() {
        extract_tree(child, root)?;
    }
    Ok(())
}

pub(crate) fn write_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    fs::write(path, contents)?;
    #[cfg(unix)]
    if path.extension().is_some_and(|extension| extension == "sh") {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {

    use super::*;


    #[tokio::test]
    async fn failed_upload_removes_staged_tree() {
        use crate::{
            error::RcError,
            fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep},
            transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteTransport},
        };

        let remote_dir = "/root/essence setup;literal";
        let timeout = Duration::from_secs(7);
        let mut transport = FakeTransport::new([
            ScriptStep::connect(
                ConnectExpectation::new("example.test", 22, "root", AuthMethod::System, timeout),
                Ok(()),
            ),
            ScriptStep::upload_any_local(
                remote_dir,
                timeout,
                Err(RcError::new("remote_failed", "upload interrupted")
                    .with_extra("reason", "connection_lost")),
            ),
        ]);
        transport.connect(ConnectOptions {
            host: "example.test".into(),
            port: 22,
            user: "root".into(),
            auth: Authentication::System,
            host_key: HostKeyPolicy::default(),
            timeout,
        }).await.unwrap();

        assert!(ServerBundle.upload(&transport, remote_dir, timeout).await.is_err());
        let journal = transport.journal();
        let local_dir = journal.iter().find_map(|operation| match operation {
            Operation::Upload { local_dir, .. } => Some(local_dir),
            _ => None,
        }).expect("upload must have begun");
        assert!(!local_dir.exists(), "failed upload retained its staging directory");
    }

    #[cfg(unix)]
    #[test]
    fn materialized_shell_files_are_executable_inside_private_directory() {
        use std::os::unix::fs::PermissionsExt;

        let directory = ServerBundle.materialize().unwrap();
        assert_eq!(fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777, 0o700);
        fn check_shell_modes(directory: &Path) {
            for entry in fs::read_dir(directory).unwrap() {
                let path = entry.unwrap().path();
                let metadata = fs::metadata(&path).unwrap();
                if metadata.is_dir() {
                    check_shell_modes(&path);
                } else if path.extension().is_some_and(|extension| extension == "sh") {
                    assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
                }
            }
        }
        check_shell_modes(directory.path());
    }
}

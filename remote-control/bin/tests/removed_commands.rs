//! User-facing texts never point at commands that no longer exist. Lives in
//! the binary crate, which depends on every crate whose sources it scans
//! (catalog and help in core, TUI, web assets). `docs/` is rewritten for the
//! new model in stage 7 and joins the scan then.

use std::path::{Path, PathBuf};

/// Removed with stage 2 (`node apply` owns the server state).
const REMOVED: [&str; 1] = [concat!("upload", "-scripts")];

fn files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files(&path, out);
        } else if path.extension().is_some_and(|ext| matches!(ext.to_str(), Some("rs" | "js" | "mjs" | "html"))) {
            out.push(path);
        }
    }
}

#[test]
fn no_text_mentions_a_removed_command() {
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut sources = Vec::new();
    for dir in ["core/src", "client/src", "bin/src", "tui/src", "web/src", "web/assets"] {
        files(&workspace.join(dir), &mut sources);
    }
    assert!(sources.len() > 50, "{} sources", sources.len());
    for path in sources {
        let text = std::fs::read_to_string(&path).unwrap();
        for command in REMOVED {
            assert!(!text.contains(command), "{} mentions {command}", path.display());
        }
    }
}

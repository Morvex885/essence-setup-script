//! The TUI's sole core interface is a serve-v2 child process, and the TUI is
//! a library linked into the single `essence-rc` executable.
use std::{fs, path::Path};
fn scan(path: &Path) {
    for entry in fs::read_dir(path).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            scan(&path);
        } else if path.extension().is_some_and(|s| s == "rs") {
            let source = fs::read_to_string(&path).unwrap();
            assert!(!source.contains("rc_core::") && !source.contains("use rc_core"), "core import in {}", path.display());
        }
    }
}
#[test]
fn tui_cannot_import_core() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let manifest = fs::read_to_string(root.join("Cargo.toml")).unwrap();
    assert!(!manifest.contains("rc-core"));
    scan(&root.join("src"));
}
#[test]
fn tui_is_a_library_of_the_single_binary() {
    // No second executable: the menu ships inside `essence-rc`.
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let manifest = fs::read_to_string(root.join("Cargo.toml")).unwrap();
    assert!(!manifest.contains("[[bin]]") && !root.join("src/main.rs").exists() && !root.join("src/bin").exists());
}

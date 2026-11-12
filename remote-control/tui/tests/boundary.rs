//! Front ends reach the core only through the daemon protocol: neither the
//! TUI, the client crate nor the web listener depends on `rc-core`, and the
//! TUI is a library linked into the single `essence-rc` executable.
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
fn assert_without_core(root: &Path) {
    let manifest = fs::read_to_string(root.join("Cargo.toml")).unwrap();
    assert!(!manifest.contains("rc-core"), "rc-core in {}", root.display());
    scan(&root.join("src"));
}
#[test]
fn tui_client_and_web_cannot_import_core() {
    let tui = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert_without_core(tui);
    assert_without_core(&tui.join("../client"));
    assert_without_core(&tui.join("../web"));
}
#[test]
fn tui_is_a_library_of_the_single_binary() {
    // No second executable: the menu ships inside `essence-rc`.
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let manifest = fs::read_to_string(root.join("Cargo.toml")).unwrap();
    assert!(!manifest.contains("[[bin]]") && !root.join("src/main.rs").exists() && !root.join("src/bin").exists());
}

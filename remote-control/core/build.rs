fn main() {
    let version = include_str!("../../VERSION").trim();
    assert!(!version.is_empty(), "root VERSION must not be empty");
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=ESSENCE_RC_VERSION={version}");
}

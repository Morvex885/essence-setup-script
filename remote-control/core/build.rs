fn main() {
    let version = include_str!("../../VERSION").trim();
    assert!(!version.is_empty(), "root VERSION must not be empty");
    println!("cargo:rerun-if-changed=../../VERSION");
    // `include_dir!` does not track its inputs on stable; a changed file in a
    // directory listed here reruns this script and rebuilds `bundle.rs`.
    println!("cargo:rerun-if-changed=../../setup-essence");
    println!("cargo:rerun-if-changed=../../common");
    println!("cargo:rustc-env=ESSENCE_RC_VERSION={version}");
}

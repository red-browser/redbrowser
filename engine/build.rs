//! Embed the exact versions of the engine crates (from Cargo.lock) and the Rust
//! compiler, so `about:firefox` reports what is actually linked in.

use std::process::Command;

const CRATES: &[&str] = &[
    "webrender",
    "webrender_api",
    "wr_glyph_rasterizer",
    "gleam",
    "html5ever",
    "markup5ever",
    "image",
    "ttf-parser",
];

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    let lock = std::fs::read_to_string("Cargo.lock").unwrap_or_default();
    let mut out = String::new();
    for name in CRATES {
        let version = locked_version(&lock, name).unwrap_or_else(|| "unknown".into());
        out.push_str(&format!("{name}={version}\n"));
    }
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let rustc_version = Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".into());
    out.push_str(&format!("rustc={rustc_version}\n"));
    println!("cargo:rustc-env=REDENGINE_VERSIONS={}", out.replace('\n', ";"));
}

/// First `version = "..."` after `name = "<name>"` in Cargo.lock.
fn locked_version(lock: &str, name: &str) -> Option<String> {
    let needle = format!("name = \"{name}\"\n");
    let start = lock.find(&needle)? + needle.len();
    let line = lock[start..].lines().next()?;
    let v = line.strip_prefix("version = \"")?.strip_suffix('"')?;
    Some(v.to_string())
}

use std::env;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("Cargo manifest directory");
    let manifest_dir = Path::new(&manifest_dir);
    let root = manifest_dir.join("../..");
    let engine = root.join("Build/vendor/pdf-inspector");
    let patch_path = root.join("Patches/pdf-inspector-embed-apple-cmaps.patch");

    let revision_path = root.join("ENGINE_REVISION");
    let expected_revision = read(&revision_path).trim().to_owned();
    assert!(
        expected_revision.len() == 40
            && expected_revision
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "ENGINE_REVISION must contain one lowercase 40-character Git revision"
    );

    let expected_version = dependency_version(&read(&manifest_dir.join("Cargo.toml")));
    let locked_version = locked_version(&read(&manifest_dir.join("Cargo.lock")));
    assert_eq!(
        expected_version, locked_version,
        "pdf-inspector dependency and Cargo.lock versions differ"
    );

    let engine_manifest = engine.join("Cargo.toml");
    let actual_version = package_version(&read(&engine_manifest));
    assert_eq!(
        expected_version, actual_version,
        "the prepared pdf-inspector version does not match the exact dependency pin"
    );

    let output = git_output(&engine, None, &["rev-parse", "HEAD"]);
    assert!(
        output.status.success(),
        "could not read the prepared pdf-inspector revision"
    );
    let actual_revision = String::from_utf8(output.stdout)
        .expect("pdf-inspector revision is UTF-8")
        .trim()
        .to_owned();
    assert_eq!(
        expected_revision, actual_revision,
        "the prepared pdf-inspector revision does not match ENGINE_REVISION"
    );

    let expected_index = TemporaryIndex::new("expected");
    let output = git_output(&engine, Some(expected_index.path()), &["read-tree", "HEAD"]);
    assert!(
        output.status.success(),
        "could not prepare the expected pdf-inspector tree"
    );
    let output = git_output(
        &engine,
        Some(expected_index.path()),
        &[
            "apply",
            "--cached",
            "--",
            patch_path.to_str().expect("patch path is UTF-8"),
        ],
    );
    assert!(
        output.status.success(),
        "could not apply the tracked Apple CMap patch"
    );
    let expected_tree = write_tree(&engine, expected_index.path());

    let actual_index = TemporaryIndex::new("actual");
    let output = git_output(&engine, Some(actual_index.path()), &["read-tree", "HEAD"]);
    assert!(
        output.status.success(),
        "could not prepare the actual pdf-inspector tree"
    );
    let output = git_output(
        &engine,
        Some(actual_index.path()),
        &["add", "-u", "--", "."],
    );
    assert!(
        output.status.success(),
        "could not stage the prepared pdf-inspector tree"
    );
    let actual_tree = write_tree(&engine, actual_index.path());
    assert_eq!(
        expected_tree, actual_tree,
        "the prepared pdf-inspector tree does not match ENGINE_REVISION plus the tracked Apple CMap patch"
    );

    for args in [
        &["ls-files", "--others", "--exclude-standard"][..],
        &["ls-files", "--others", "--ignored", "--exclude-standard"][..],
    ] {
        let output = git_output(&engine, None, args);
        assert!(
            output.status.success(),
            "could not inspect untracked pdf-inspector files"
        );
        assert!(
            output.stdout.is_empty(),
            "the prepared pdf-inspector tree contains untracked or ignored files"
        );
    }

    println!("cargo:rustc-env=DOCUMENTKIT_PDF_INSPECTOR_VERSION={expected_version}");
    println!("cargo:rustc-env=DOCUMENTKIT_PDF_INSPECTOR_REVISION={expected_revision}");
    println!("cargo:rerun-if-changed={}", revision_path.display());
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("Cargo.toml").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("Cargo.lock").display()
    );
    println!("cargo:rerun-if-changed={}", patch_path.display());
    println!("cargo:rerun-if-changed={}", engine.display());
    println!("cargo:rerun-if-changed={}", engine_manifest.display());
    println!(
        "cargo:rerun-if-changed={}",
        engine.join(".git/HEAD").display()
    );
}

fn read(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("could not read {}: {error}", path.display()))
}

struct TemporaryIndex {
    path: std::path::PathBuf,
}

impl TemporaryIndex {
    fn new(label: &str) -> Self {
        for attempt in 0..100 {
            let path = env::temp_dir().join(format!(
                "documentkit-pdf-inspector-{label}-{}-{attempt}",
                std::process::id()
            ));
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(_) => return Self { path },
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("could not create temporary Git index: {error}"),
            }
        }
        panic!("could not create temporary Git index");
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryIndex {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        let mut lock_path = self.path.as_os_str().to_owned();
        lock_path.push(".lock");
        let _ = fs::remove_file(std::path::PathBuf::from(lock_path));
    }
}

fn git_output(engine: &Path, index: Option<&Path>, args: &[&str]) -> Output {
    let mut command = Command::new("git");
    command.arg("-C").arg(engine);
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    command
        .args(args)
        .output()
        .expect("git is required to verify the prepared pdf-inspector tree")
}

fn write_tree(engine: &Path, index: &Path) -> String {
    let output = git_output(engine, Some(index), &["write-tree"]);
    assert!(
        output.status.success(),
        "could not write the prepared pdf-inspector tree"
    );
    String::from_utf8(output.stdout)
        .expect("pdf-inspector tree ID is UTF-8")
        .trim()
        .to_owned()
}

fn dependency_version(manifest: &str) -> String {
    let line = manifest
        .lines()
        .find(|line| line.starts_with("pdf-inspector = "))
        .expect("Cargo.toml must declare pdf-inspector");
    value_after(line, "version = \"=")
        .expect("pdf-inspector must use an exact version pin")
        .to_owned()
}

fn locked_version(lockfile: &str) -> String {
    lockfile
        .split("\n\n")
        .find(|package| {
            package
                .lines()
                .any(|line| line == "name = \"pdf-inspector\"")
        })
        .and_then(|package| {
            package
                .lines()
                .find_map(|line| value_after(line, "version = \""))
        })
        .expect("Cargo.lock must contain pdf-inspector")
        .to_owned()
}

fn package_version(manifest: &str) -> String {
    manifest
        .split_once("[package]")
        .and_then(|(_, package)| {
            package
                .lines()
                .find_map(|line| value_after(line, "version = \""))
        })
        .expect("pdf-inspector Cargo.toml must declare a package version")
        .to_owned()
}

fn value_after<'a>(line: &'a str, marker: &str) -> Option<&'a str> {
    line.split_once(marker)?.1.split('"').next()
}

#!/usr/bin/env python3
"""Collect source license texts for the SDK's locked Apple dependency trees."""

import argparse
import hashlib
from html import unescape
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Native/DocumentKitCore/Cargo.toml"
OUTPUT = ROOT / "RUST_THIRD_PARTY_LICENSES.md"
TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
    "x86_64-apple-ios",
)
NOTICE = re.compile(r"(?:licen[cs]e|unlicense|copying|notice|copyright|patents)(?:$|[._-])", re.I)
# These crates omit their workspace-root license when published to crates.io.
OVERRIDES = {
    ("alloc-stdlib", "0.2.4"): (
        "alloc-stdlib-0.2.4-LICENSE",
        "ae42d22078b98549e987d2f03d12df7b984fde47",
    ),
    ("include_dir", "0.7.4"): (
        "include_dir-0.7.4-LICENSE",
        "d742c6fffce99ee89da91b934e7ce6fb2a82680c",
    ),
    ("include_dir_macros", "0.7.4"): (
        "include_dir-0.7.4-LICENSE",
        "d742c6fffce99ee89da91b934e7ce6fb2a82680c",
    ),
}


def cargo(*arguments):
    return subprocess.check_output(
        ["cargo", *arguments, "--locked", "--color", "never", "--manifest-path", str(MANIFEST)],
        cwd=ROOT, text=True,
    )


def runtime_notices(notices):
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], cwd=ROOT, text=True).strip())
    source = sysroot / "share/doc/rust"
    document = (source / "COPYRIGHT-library.html").read_text(encoding="utf-8")
    in_tree = document.split('<h2 id="in-tree-files">', 1)[1].split('<h2 id="out-of-tree-dependencies">', 1)[0]
    credits = unescape(re.sub(r"<[^>]+>", "", in_tree))
    credits = "\n".join(line.strip() for line in credits.splitlines() if line.strip())
    version = subprocess.check_output(["rustc", "--version"], cwd=ROOT, text=True).strip()
    for filename in ("MIT.txt", "Unicode-3.0.txt", "BSD-2-Clause.txt"):
        text = (source / "licenses" / filename).read_text(encoding="utf-8").rstrip() + "\n"
        notices.setdefault(text, []).append(f"`{version}`: `licenses/{filename}`")

    # The toolchain document covers every platform. Retain dependency notices
    # only for crates present in the installed Apple standard libraries.
    crates = set()
    for target in TARGETS:
        libraries = list((sysroot / "lib/rustlib" / target / "lib").glob("lib*.rlib"))
        if not libraries:
            raise ValueError(f"Rust standard library is not installed for {target}")
        crates.update(path.stem.rsplit("-", 1)[0][3:] for path in libraries)
    sections = re.findall(r"<h3>(.*?)</h3>(.*?)(?=<h3>|</body>)", document, re.S)
    if not sections:
        raise ValueError("No Rust standard-library dependency notices found")
    for heading, section in sections:
        package = unescape(heading).removeprefix("📦 ")
        name = package.rsplit("-", 1)[0].replace("-", "_")
        if name not in crates:
            continue
        entries = re.findall(r"<summary><code>(.*?)</code></summary>\s*<pre>(.*?)</pre>", section, re.S)
        if not entries:
            raise ValueError(f"No Rust runtime license texts found for {package}")
        for filename, encoded in entries:
            text = unescape(encoded).strip() + "\n"
            notices.setdefault(text, []).append(f"`{version}, {package}`: `{unescape(filename)}`")
    return ["## Rust standard library", "", version, "", "In-tree attributions:", "", "```text", credits, "```", ""]


def generate():
    packages = {}
    for target in TARGETS:
        metadata = json.loads(cargo("metadata", "--filter-platform", target,
                                    "--format-version", "1"))
        candidates = {}
        for package in metadata["packages"]:
            key = (package["name"], package["version"])
            if key in candidates:
                raise ValueError(f"Ambiguous package source: {key}")
            candidates[key] = package
        # Cargo metadata unifies optional features across targets. `cargo tree`
        # selects the features actually built for each Apple target instead.
        tree = cargo("tree", "--target", target, "--edges", "normal,build",
                     "--prefix", "none", "--format", "{p}")
        for line in tree.splitlines():
            match = re.match(r"(\S+) v(\S+)(?: |$)", line)
            if not match:
                raise ValueError(f"Unexpected cargo tree entry: {line}")
            key = match.groups()
            package = candidates[key]
            if package["id"] != metadata["resolve"]["root"]:
                packages[key] = package

    notices = {}
    for key, package in sorted(packages.items()):
        directory = Path(package["manifest_path"]).parent
        sources = []
        for parent, directories, filenames in os.walk(directory):
            directories[:] = sorted(d for d in directories if d not in (".git", "target"))
            for filename in sorted(filenames):
                if NOTICE.match(filename):
                    path = Path(parent) / filename
                    sources.append((path, str(path.relative_to(directory))))
        if package["license_file"]:
            path = directory / package["license_file"]
            if path not in [source[0] for source in sources]:
                sources.append((path, str(path.relative_to(directory))))
        if key in OVERRIDES:
            filename, revision = OVERRIDES[key]
            vcs = json.loads((directory / ".cargo_vcs_info.json").read_text(encoding="utf-8"))
            if vcs["git"]["sha1"] != revision:
                raise ValueError(f"License override source revision changed: {key}")
            sources.append((ROOT / "Scripts/LicenseOverrides" / filename,
                            f"LICENSE at {revision}"))
        if not sources:
            raise ValueError(f"No source license or notice files found: {key}")
        for path, relative in sources:
            text = path.read_text(encoding="utf-8").rstrip() + "\n"
            if not text.strip():
                raise ValueError(f"Empty source notice: {key}, {relative}")
            notices.setdefault(text, []).append(f"`{key[0]} {key[1]}`: `{relative}`")

    runtime = runtime_notices(notices)
    lines = [
        "# Rust third-party licenses", "",
        "License and notice texts for the locked normal and build dependencies",
        "of Turnip's five Apple targets. Development-only dependencies are excluded.",
        "Generated by `python3 Scripts/generate-rust-licenses.py`. Do not edit by hand.",
        "Bundled asset notices are also provided in `THIRD_PARTY_NOTICES.md`.",
        "Rust standard-library attributions and license texts are included below.", "",
        "## Components", "", "| Package | Version | Declared license |",
        "| --- | --- | --- |",
    ]
    for (name, version), package in sorted(packages.items()):
        license_text = (package["license"] or package["license_file"] or "Undeclared").replace("|", "\\|")
        lines.append(f"| {name} | {version} | {license_text} |")
    lines += [""] + runtime + ["## License and notice texts", ""]
    for text, sources in notices.items():
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
        fence = "`" * max(3, max((len(m) + 1 for m in re.findall(r"`+", text)), default=0))
        lines += [f"### Notice {digest}", "", "Sources:", ""]
        lines += [f"- {source}" for source in sorted(sources)]
        lines += ["", f"{fence}text", text.rstrip(), fence, ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed notices are stale")
    arguments = parser.parse_args()
    generated = generate()
    if arguments.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != generated:
            sys.exit("Rust notices are stale. Run python3 Scripts/generate-rust-licenses.py")
    else:
        OUTPUT.write_text(generated, encoding="utf-8")
    print("Rust third-party licenses verified." if arguments.check else "Generated Rust third-party licenses.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, subprocess.CalledProcessError) as error:
        sys.exit(f"Could not collect Rust licenses: {error}")

#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"

NOTICE_BASENAME = /\A(?:licen[cs]e|copying|notice|copyright|patents)(?:\z|[._-])/i
IGNORED_DIRECTORIES = [".git", "target"].freeze
INCLUDE_DIR_REVISION = "d742c6fffce99ee89da91b934e7ce6fb2a82680c"
INCLUDE_DIR_LICENSE_SHA256 = "9369f62987b3a116111f2edfdc4cc72633e44ddc94d5d0c68659cf537b76a31f"

root, discovery_path, output_path = ARGV
unless ARGV.length == 3
  warn "Usage: #{$PROGRAM_NAME} REPOSITORY_ROOT CARGO_ABOUT_JSON OUTPUT"
  exit 2
end

override_path = File.join(root, "Scripts", "LicenseOverrides", "include_dir-0.7.4-LICENSE")
overrides = {
  "include_dir@0.7.4" => [override_path, INCLUDE_DIR_LICENSE_SHA256],
  "include_dir_macros@0.7.4" => [override_path, INCLUDE_DIR_LICENSE_SHA256]
}.freeze

def normalized_notice(path)
  text = File.binread(path).force_encoding(Encoding::UTF_8)
  raise "Notice is not valid UTF-8: #{path}" unless text.valid_encoding?

  text = text.gsub(/\r\n?/, "\n")
  text = text.lines.map { |line| line.sub(/[ \t]+(?=\n|\z)/, "") }.join
  "#{text.rstrip}\n"
end

def markdown_cell(value)
  value.to_s.gsub("|", "\\|").gsub("\n", " ")
end

def code_fence(text)
  longest = text.scan(/`+/).map(&:length).max || 0
  "`" * [3, longest + 1].max
end

discovery = JSON.parse(File.read(discovery_path, encoding: "UTF-8"))
packages = discovery.fetch("crates").map { |entry| entry.fetch("package") }
packages.sort_by! { |package| [package.fetch("name").downcase, package.fetch("version")] }

synthesized_packages = discovery.fetch("licenses").select do |license|
  license["source_path"].nil?
end.flat_map do |license|
  license.fetch("used_by").map do |used_by|
    crate = used_by.fetch("crate")
    "#{crate.fetch("name")}@#{crate.fetch("version")}"
  end
end.uniq.sort

uncovered_synthesized = synthesized_packages - overrides.keys
unless uncovered_synthesized.empty?
  raise "Missing source-license overrides for: #{uncovered_synthesized.join(", ")}"
end

stale_overrides = overrides.keys - packages.map { |package| "#{package.fetch("name")}@#{package.fetch("version")}" }
unless stale_overrides.empty?
  raise "Stale source-license overrides for: #{stale_overrides.join(", ")}"
end

notices = {}

packages.each do |package|
  name = package.fetch("name")
  version = package.fetch("version")
  package_key = "#{name}@#{version}"
  package_root = File.dirname(package.fetch("manifest_path"))
  sources = []

  Find.find(package_root) do |path|
    if File.directory?(path)
      if path != package_root && IGNORED_DIRECTORIES.include?(File.basename(path))
        Find.prune
      else
        next
      end
    end

    next unless File.file?(path)
    next unless File.basename(path).match?(NOTICE_BASENAME)

    sources << [path, path.delete_prefix("#{package_root}/")]
  end

  if overrides.key?(package_key)
    path, expected_sha256 = overrides.fetch(package_key)
    actual_sha256 = Digest::SHA256.file(path).hexdigest
    unless actual_sha256 == expected_sha256
      raise "License override checksum mismatch for #{package_key}: #{actual_sha256}"
    end
    sources << [path, "LICENSE at #{INCLUDE_DIR_REVISION}"]
  end

  raise "No license or notice files found for #{package_key}" if sources.empty?

  sources.sort_by { |source| source.fetch(1) }.each do |path, display_path|
    text = normalized_notice(path)
    digest = Digest::SHA256.hexdigest(text)
    notice = notices[digest] ||= { "text" => text, "sources" => [] }
    notice.fetch("sources") << {
      "name" => name,
      "version" => version,
      "path" => display_path
    }
  end
end

File.open(output_path, "wb", 0o644) do |output|
  output.write <<~HEADER
    # Rust third-party licenses

    This file lists the Rust packages used to build the core shipped in
    DocumentKit's Apple binary. The component graph covers normal and build
    dependencies for every supported Apple target and excludes development-only
    dependencies. It is generated from `Native/DocumentKitCore/Cargo.lock` by
    `Scripts/generate-rust-licenses.sh`. Do not edit it by hand.

    Every `LICENSE*`, `LICENCE*`, `COPYING*`, `NOTICE*`, `COPYRIGHT*`, and
    `PATENTS*` file found in the resolved package sources is reproduced below.
    Identical texts are stored once and list every package source that uses them.

    ## Components

    | Package | Version | Declared license |
    | --- | --- | --- |
  HEADER

  packages.each do |package|
    name = package.fetch("name")
    version = package.fetch("version")
    repository = package["repository"] || "https://crates.io/crates/#{name}"
    license = package["license"] || package["license_file"] || "Undeclared"
    output.puts "| [#{markdown_cell(name)}](#{repository}) | `#{markdown_cell(version)}` | `#{markdown_cell(license)}` |"
  end

  output.write <<~INTRO

    ## License and notice texts

  INTRO

  sorted_notices = notices.sort_by do |digest, notice|
    first = notice.fetch("sources").min_by do |source|
      [source.fetch("name").downcase, source.fetch("version"), source.fetch("path")]
    end
    [first.fetch("name").downcase, first.fetch("version"), first.fetch("path"), digest]
  end

  sorted_notices.each_with_index do |(digest, notice), index|
    sources = notice.fetch("sources").uniq.sort_by do |source|
      [source.fetch("name").downcase, source.fetch("version"), source.fetch("path")]
    end
    labels = sources.map { |source| File.basename(source.fetch("path").split(" at ").first) }.uniq.sort
    output.puts "### #{labels.join(" / ")} (`#{digest[0, 12]}`)"
    output.puts
    output.puts "Sources:"
    output.puts
    sources.each do |source|
      output.puts "- `#{source.fetch("name")} #{source.fetch("version")}`: `#{source.fetch("path")}`"
    end
    output.puts
    fence = code_fence(notice.fetch("text"))
    output.puts "#{fence}text"
    output.write notice.fetch("text")
    output.puts fence
    output.puts if index < sorted_notices.length - 1
  end
end

File.chmod(0o644, output_path)

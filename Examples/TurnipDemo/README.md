# Turnip Demo

This small native SwiftUI app exercises Turnip through its public Swift
API on iOS and macOS. Both versions open PDFs, process the entire document or
a strictly ascending comma-separated page selection, accept an optional PDF
password, and show requested-page coverage plus the encoded structured
document. The macOS layout also displays the source PDF beside the JSON and
accepts file drops. Passwords stay in memory and are never saved by the app.

The app does not import `DocumentKitCore` or Rust modules. For tagged releases,
SwiftPM downloads the prebuilt `DocumentKitCore.xcframework` archive from
GitHub Releases automatically. In an unreleased local checkout or after editing
the Rust engine, run `Scripts/build-xcframework.sh` first (and set
`TURNIP_USE_LOCAL_XCFRAMEWORK=1` when overriding a published release URL), then
open `TurnipDemo.xcodeproj` in Xcode and run the `TurnipDemo` scheme on iOS 16
or later or macOS 13 or later.

A convenient sample file is
`../../Benchmarks/Fixtures/Smoke/synthetic-amex-standard.pdf`.

The app intentionally shows the public JSON without another presentation
layer. This makes page coverage, reading order, table cells, warnings, and
geometry visible during development.

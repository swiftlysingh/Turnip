# DocumentKit Demo

This small native SwiftUI app exercises DocumentKit through its public Swift
API on iOS and macOS. Both versions open PDFs, process the entire document or
a strictly ascending comma-separated page selection, accept an optional PDF
password, and show the exact extracted Markdown. The macOS layout also displays
the source PDF beside the Markdown and accepts file drops. Passwords stay in
memory and are never saved by the app.

The app does not import `DocumentKitCore`, Rust modules, or any Markdown
rendering dependency. Build the engine artifact first so the local
`DocumentKit` package can resolve its `DocumentKitCore.xcframework` binary
target:

```sh
../../Scripts/build-xcframework.sh
```

Then open `DocumentKitDemo.xcodeproj` in Xcode and run the `DocumentKitDemo`
scheme on iOS 16 or later or macOS 13 or later.

The app intentionally keeps the Markdown unrendered. This makes extraction
ordering, tables, warnings, and encoding issues visible during development.

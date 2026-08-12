# DocumentKit Demo

This small macOS SwiftUI app exercises DocumentKit through its public Swift
API. It opens or accepts a dropped PDF, displays the original with PDFKit,
and shows the exact extracted Markdown beside it. The options bar can process
the entire PDF or a strictly ascending, comma-separated page selection. It can
also pass a password to both PDFKit preview and DocumentKit extraction; the
password stays in memory and is never saved by the app.

The app does not import `DocumentKitCore`, Rust modules, or any Markdown
rendering dependency. Build the engine artifact first so the local
`DocumentKit` package can resolve its `DocumentKitCore.xcframework` binary
target:

```sh
../../Scripts/build-xcframework.sh
```

Then open `DocumentKitDemo.xcodeproj` in Xcode and run the `DocumentKitDemo`
scheme on macOS 13 or later.

The app intentionally keeps the Markdown unrendered. This makes extraction
ordering, tables, warnings, and encoding issues visible during development.

# Turnip Demo

This small native SwiftUI app exercises Turnip through its public Swift
API on iOS and macOS. Both versions open PDFs, process the entire document or
a strictly ascending comma-separated page selection, accept an optional PDF
password, and show requested-page coverage plus the encoded structured
document. The macOS layout also displays the source PDF beside the JSON and
accepts file drops. Passwords stay in memory and are never saved by the app.

The app does not import `DocumentKitCore` or Rust modules. Build the engine
artifact first so the local
`Turnip` package can resolve its `DocumentKitCore.xcframework` binary
target:

```sh
../../Scripts/build-xcframework.sh
```

Then open `TurnipDemo.xcodeproj` in Xcode and run the `TurnipDemo`
scheme on iOS 16 or later or macOS 13 or later.

The app intentionally shows the public JSON without another presentation
layer. This makes page coverage, reading order, table cells, warnings, and
geometry visible during development.

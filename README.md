<p align="center">
  <img src="Assets/banner.svg" alt="Jayson" width="800">
</p>

<p align="center">
  <a href="https://github.com/axel-eck/jayson/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/axel-eck/jayson?display_name=tag"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-lightgrey">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange">
</p>

Jayson is a native macOS app for working with JSON. Paste a document and clean, format,
search and edit it as a tree. Infer a JSON Schema from it, write one by hand or load one from
a file or URL, then validate against it and get errors that point at the offending node.
Chain scripts, HTTP requests and queries into pipelines that transform the document.

## Features

### Editing and formatting

- Paste and format in one step. Clean repairs comments, trailing commas, single quotes,
  unquoted keys, code fences and string-encoded ("double-encoded") JSON.
- Format, minify or sort keys, with 2-space, 4-space or tab indentation.
- The tree view shows type colours, child counts and the selected path in the status bar. From
  its context menu you can edit any value as JSON, rename keys, add properties, duplicate or
  delete nodes, copy a value, path or JSON Pointer, and expand or collapse subtrees. Tree edits
  can be undone.
- In arrays of objects, Add Item inserts an element shaped like its siblings. Jayson infers
  the siblings' schema for this, or uses the `items` schema when one is loaded. Infer Item
  Schema puts that inferred schema in the schema panel.

### Search and queries

- Search across keys and values, or query with JSONPath. Recursive descent, slices, filters
  with `&&`, `||` and `!`, and regular expressions are supported, for example
  `$.store.book[?(@.price < 10)].title`.
- Matches are highlighted in the tree and listed with their paths. Results can be copied as a
  JSON array.

### Schemas and validation

- Infer a schema from the current document, start from a blank template, open a file or load
  one from a URL.
- Schemas live in a sidebar library that persists between launches. Any schema can be applied
  to any open document.
- Validation supports drafts 4 through 2020-12 and runs live as you type in either the document
  or the schema. Errors are listed with their instance path and keyword, in the style of
  regex101, and clicking one reveals the node.

### Pipelines

A pipeline chains blocks that transform the document, a bit like a small n8n for JSON.

- Script blocks run JavaScript or TypeScript. The block receives `input` and returns the new
  value, with helpers such as `$.flatten`, `$.pick`, `$.groupBy` and `$.jsonPath`.
- TypeScript blocks are type-checked by the bundled TypeScript compiler against an `Input` type
  derived from the loaded schema, or inferred from the step's actual input when there is none.
- HTTP blocks send a request with a chosen method, headers and body. The body can be the step
  input or custom text, `{{ path }}` placeholders are filled from the input, and the response is
  parsed as JSON.
- JSONPath and Flatten blocks select or reshape the data, and a block can run another pipeline
  from the library.
- Pipelines run live as you type and show every step's output. HTTP requests are only sent when
  you press Run and are replayed from a cache otherwise.
- A pipeline can be reused on any document, exported and imported as JSON, applied back to the
  document, or opened as a new document.

### Workspace

- Documents open as tabs in a window with a hidden title bar and a flat sidebar layout.
- Light and dark mode are fully supported.
- Jayson restores your session on launch: open documents with their schemas and pipelines, the
  schema and pipeline libraries, the selection and the panel layout. The session is stored in
  `~/Library/Application Support/Jayson/session.json`. The sample document only appears on the
  first launch.

## Installation

### Homebrew

```sh
brew install --cask axel-eck/tap/jayson
```

The app is not notarized yet, so Gatekeeper refuses to open it the first time. Either clear
the quarantine flag or right-click `Jayson.app` in `/Applications` and choose Open once:

```sh
xattr -dr com.apple.quarantine /Applications/Jayson.app
```

### From source

```sh
make install
```

This builds a release app and copies it into `~/Applications`. See [Building](#building) for
requirements.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Format / Minify / Clean | ⇧⌘F / ⇧⌘M / ⇧⌘K |
| Paste and format | ⌥⇧⌘V |
| Copy formatted / minified | ⇧⌘C / ⌥⇧⌘C |
| Find / JSONPath query | ⌘F / ⇧⌘P |
| Next / previous match | ⌘G / ⇧⌘G |
| Infer schema | ⇧⌘I |
| Validate now | ⌘R |
| Toggle sidebar / schema panel / pipeline panel | ⌃⌘S / ⌥⌘I / ⌥⌘P |
| Run pipeline / pipeline output as new document | ⌥⌘R / ⌥⇧⌘N |
| Source / Split / Tree view | ⌘1 / ⌘2 / ⌘3 |
| New / close document | ⌘N / ⌘W |
| Expand / collapse all | ⌥⌘E / ⌥⇧⌘E |

## Building

Jayson is a Swift package built with SwiftUI and targets macOS 14 or later. The Command Line
Tools are enough to build it; Xcode is not required, though you can open `Package.swift` in
Xcode if you prefer an IDE.

```sh
make app          # release build wrapped into build/Jayson.app
make run          # build and open the app
make test         # run the JaysonCore checks
make typescript   # download the TypeScript compiler used by pipeline script steps (~9 MB, not committed)
make icon         # regenerate Assets/AppIcon.icns from Assets/logo.svg
make banner       # regenerate the README banner (Assets/banner.svg and .png) from Assets/logo.svg
swift run Jayson  # quick development launch as a bare executable
```

### Toolchain notes

- `Scripts/sdk.sh` picks a non-beta macOS SDK. Beta SDKs turn `@State` into a macro whose
  compiler plugin only ships with Xcode, which breaks SwiftUI builds under the Command Line
  Tools. Set `SDKROOT` yourself to override the choice.
- Neither XCTest nor Swift Testing is available with the Command Line Tools, so the tests are a
  plain executable target, `JaysonCoreChecks`, with a small assertion harness. Run it with
  `make test` or `swift run JaysonCoreChecks`.
- Pipeline scripts run in JavaScriptCore. TypeScript support needs the compiler in
  `Resources/TypeScript`, which `make typescript` fetches from jsDelivr together with the ES2020
  lib declarations. The app build copies it into the bundle, and `TypeScriptService` also looks
  in `~/Library/Application Support/Jayson/TypeScript` and `$JAYSON_TYPESCRIPT_DIR`. Without it,
  JavaScript steps keep working and TypeScript steps report that the compiler is missing.

### Environment variables

Both are mainly useful for screenshots.

| Variable | Effect |
| --- | --- |
| `JAYSON_APPEARANCE=dark` or `light` | Forces the appearance at launch. |
| `JAYSON_SESSION_PATH=/path/to/session.json` | Uses a different session file. A path that does not exist yet behaves like a first launch and shows the sample document. |

## Project layout

```
Sources/JaysonCore/          Pure logic, no UI dependencies
  JSONValue.swift            Ordered JSON model, paths, semantic equality, path mutation
  JSONParser.swift           Strict and lenient parser with line/column errors
  JSONFormatter.swift        Pretty printer, minifier, and the "clean" repair pipeline
  JSONPath.swift             JSONPath query engine
  TextSearch.swift           Key/value text search
  SchemaValidator*.swift     JSON Schema validator and format assertions
  SchemaInference.swift      Schema inference and merging
  SchemaInstance.swift       Instance generation from a schema
  SchemaLocator.swift        Finds the sub-schema for an instance path
  ArrayItemTemplate.swift    Template for "Add Item" (schema first, then inferred)
  Pipeline.swift             Pipeline/step model and its JSON encoding
  PipelineRunner.swift       Runs steps in sequence; JSONPath, flatten and nested pipelines
  ScriptEngine.swift         JavaScriptCore host for script steps: `$` helpers, console, time limit
  TypeScriptService.swift    Bundled TypeScript compiler: transpile and type-check steps
  SchemaTypeScript.swift     JSON Schema to TypeScript declarations
Sources/Jayson/              SwiftUI app
  Workspace.swift            Documents (tabs), schema and pipeline libraries, chrome state
  DocumentModel.swift        Per-document state: parsing, search, tree edits, validation
  PipelineSupport.swift      Per-document pipeline runs, step editing, previews, type checks
  MainWindow.swift           Sidebar | tabbed document area | schema or pipeline panel
  Sidebar.swift, SchemaPanel.swift, PipelinePanel.swift, Panes.swift, JSONTreeView.swift, Sheets.swift
  SourceEditor.swift         NSTextView wrapper with syntax colouring
  Controls.swift, Theme.swift
Sources/JaysonCoreChecks/    Check suites for the core library
Scripts/                     Build, icon, banner and SDK helpers
Assets/                      Logo, generated app icon and README banner
```

## Releasing

Releases are universal zips (Apple Silicon and Intel) attached to GitHub Releases, plus a
Homebrew cask in the tap repository.

1. Bump `VERSION`, commit, and tag: `git tag v0.2.0 && git push origin main v0.2.0`.
2. The `Release` workflow builds the app on a macOS runner and creates the GitHub Release with
   `Jayson-<version>.zip`. When the `HOMEBREW_TAP_TOKEN` secret is set, it also commits the
   regenerated `Casks/jayson.rb` to the tap repository.
3. To publish by hand instead, `make release` runs the same build locally and writes
   `dist/Jayson-<version>.zip` and `dist/jayson.rb`.

For a signed and notarized build, set the secrets `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_APP_PASSWORD`.
Without them the build is ad-hoc signed and the cask carries the Gatekeeper caveat.

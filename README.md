# Jayson

A native macOS JSON tool. Paste, clean, format, search, edit as a tree, and work with
JSON Schema: infer schemas from data, write them by hand, load them from files or URLs,
and validate documents against them with located, human-readable errors.

![Jayson icon](Assets/AppIcon-256.png)

## Features

- **Paste and format** JSON. *Clean* repairs comments, trailing commas, single quotes,
  unquoted keys, code fences, and string-encoded ("double-encoded") JSON.
- **Format / Minify / Sort keys**, with 2-space, 4-space, or tab indentation.
- **Search** across keys and values, or **query with JSONPath** (`$.store.book[?(@.price < 10)].title`,
  recursive descent, slices, filters with `&& || !` and regex). Matches are highlighted in the
  tree and listed with their paths; results can be copied as a JSON array.
- **Tree view** with type colours, child counts, path in the status bar, and a context menu:
  edit any value as JSON, rename keys, add properties, duplicate, delete, copy value / path /
  JSON Pointer, expand or collapse subtrees.
- **Arrays of objects**: *Add Item* inserts a new element shaped like the existing ones (the
  schema of the siblings is inferred automatically) or, when a schema is loaded, like its
  `items` schema. *Infer Item Schema* puts that inferred schema in the schema panel.
- **Schemas**: infer from the current JSON, start from a blank template, open a file, or load
  from a URL. Schemas live in a sidebar library that persists between launches and can be
  applied to any open document.
- **Validation** (drafts 4 through 2020-12): errors are listed regex101-style with their instance
  path and keyword; clicking one reveals the node. Validation runs live as you type in either
  the document or the schema.
- Multiple documents as tabs, hidden title bar with a flat sidebar layout, full light and dark
  mode support, undo for tree edits.

## Installing

With Homebrew, from the personal tap:

```sh
brew install --cask axel-eck/tap/jayson
```

The app is not notarized yet, so Gatekeeper refuses to open it the first time. Either clear
the quarantine flag or right-click `Jayson.app` in `/Applications` and choose Open once:

```sh
xattr -dr com.apple.quarantine /Applications/Jayson.app
```

Or build from source with `make install`, which puts the app in `~/Applications`.

## Building

Jayson is a Swift Package (SwiftUI, macOS 14+). It builds with the Command Line Tools alone;
Xcode is not required.

```sh
make app        # release build wrapped into build/Jayson.app
make run        # build and open the app
make test       # run the JaysonCore checks
make icon       # regenerate Assets/AppIcon.icns from Assets/logo.svg
swift run Jayson  # quick development launch as a bare executable
```

Open `Package.swift` in Xcode if you prefer an IDE.

### Toolchain notes

- `Scripts/sdk.sh` picks a non-beta macOS SDK. Beta SDKs turn `@State` into a macro whose
  compiler plugin only ships with Xcode, which breaks SwiftUI builds under the Command Line
  Tools. Set `SDKROOT` yourself to override.
- Neither XCTest nor Swift Testing is available with the Command Line Tools, so tests are a
  plain executable target, `JaysonCoreChecks`, with a tiny assertion harness. Run it with
  `make test` or `swift run JaysonCoreChecks`.
- `JAYSON_APPEARANCE=dark|light` forces an appearance at launch (handy for screenshots).

## Layout

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
Sources/Jayson/              SwiftUI app
  Workspace.swift            Documents (tabs), schema library, chrome state
  DocumentModel.swift        Per-document state: parsing, search, tree edits, validation
  MainWindow.swift           Sidebar | tabbed document area | schema panel
  Sidebar.swift, SchemaPanel.swift, Panes.swift, JSONTreeView.swift, Sheets.swift
  SourceEditor.swift         NSTextView wrapper with syntax colouring
  Controls.swift, Theme.swift
Sources/JaysonCoreChecks/    Check suites for the core library
Scripts/                     Build, icon, and SDK helpers
Assets/                      Logo and generated app icon
```

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
| Toggle sidebar / schema panel | ⌃⌘S / ⌥⌘I |
| Source / Split / Tree view | ⌘1 / ⌘2 / ⌘3 |
| New / close document | ⌘N / ⌘W |
| Expand / collapse all | ⌥⌘E / ⌥⇧⌘E |

## Releasing

Releases are universal (Apple Silicon + Intel) zips attached to GitHub Releases, plus a
Homebrew cask in the tap repo.

1. Bump `VERSION`, commit, and tag: `git tag v0.2.0 && git push origin main v0.2.0`.
2. The `Release` workflow builds the app on a macOS runner, creates the GitHub Release with
   `Jayson-<version>.zip`, and, when the `HOMEBREW_TAP_TOKEN` secret is set, commits the
   regenerated `Casks/jayson.rb` to the tap repo.
3. Locally, `make release` does the same build and writes `dist/Jayson-<version>.zip` and
   `dist/jayson.rb` if you prefer to publish by hand.

Optional secrets for a signed and notarized build: `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD`.
Without them the build is ad-hoc signed and the cask carries the Gatekeeper caveat.

## Icon

The icon is generated from `Assets/logo.svg`: `Scripts/make-icon.sh --fg '#562C2C' --bg '#EFCB68'`
recolours the artwork, renders it onto a macOS-style rounded tile at every size, and packs
`Assets/AppIcon.icns`.

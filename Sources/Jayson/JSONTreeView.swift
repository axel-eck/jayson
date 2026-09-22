import SwiftUI
import JaysonCore

struct JSONTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let document = model.document {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedPath) {
                        TreeNodeRow(component: nil, value: document, path: .root)
                    }
                    .listStyle(.inset)
                    .font(Theme.treeFont)
                    .onChange(of: model.revealRequest) { _, request in
                        guard let request else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(request.path, anchor: .center)
                            }
                        }
                    }
                }
            } else if let error = model.parseError {
                ContentUnavailableView {
                    Label("Invalid JSON", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Go to Error") { model.jumpToParseError() }
                    Button("Clean Up") { model.clean() }
                }
            } else {
                ContentUnavailableView {
                    Label("No JSON", systemImage: "curlybraces")
                } description: {
                    Text("Paste JSON on the left, open a file, or load a URL.")
                } actions: {
                    Button("Paste") { model.pasteAndFormat() }
                    Button("Open…") { model.openFile() }
                }
            }
        }
    }
}

private struct TreeChild {
    let component: PathComponent
    let value: JSONValue
    let path: ValuePath
}

struct TreeNodeRow: View {
    let component: PathComponent?
    let value: JSONValue
    let path: ValuePath
    @Environment(AppModel.self) private var model

    var body: some View {
        if value.isContainer {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(visibleChildren, id: \.path) { child in
                    TreeNodeRow(component: child.component, value: child.value, path: child.path)
                }
                if hiddenChildCount > 0 {
                    Button {
                        model.uncappedPaths.insert(path)
                    } label: {
                        Label("Show all \(value.childCount) items (\(hiddenChildCount) more)", systemImage: "ellipsis.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                }
            } label: {
                label
            }
            .tag(path)
            .id(path)
            .listRowBackground(rowBackground)
        } else {
            label
                .tag(path)
                .id(path)
                .listRowBackground(rowBackground)
        }
    }

    private var label: some View {
        NodeLabel(component: component, value: value, path: path, errors: model.errors(at: path))
            .contextMenu { NodeContextMenu(value: value, path: path) }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { model.expanded.contains(path) },
            set: { newValue in
                if newValue { model.expanded.insert(path) } else { model.expanded.remove(path) }
            }
        )
    }

    private var allChildren: [TreeChild] {
        switch value {
        case .array(let array):
            return array.enumerated().map { TreeChild(component: .index($0), value: $1, path: path.appending(index: $0)) }
        case .object(let object):
            return object.members.map { TreeChild(component: .key($0.key), value: $0.value, path: path.appending(key: $0.key)) }
        default:
            return []
        }
    }

    private var visibleChildren: [TreeChild] {
        let children = allChildren
        if children.count > TreeLimits.childCap, !model.uncappedPaths.contains(path) {
            return Array(children.prefix(TreeLimits.childCap))
        }
        return children
    }

    private var hiddenChildCount: Int {
        max(0, value.childCount - visibleChildren.count)
    }

    private var rowBackground: Color? {
        if model.currentHitPath == path { return Theme.currentMatchBackground }
        if model.matchedPaths.contains(path) { return Theme.matchBackground }
        if model.errorsByPath[path] != nil { return Theme.errorBackground }
        return nil
    }
}

struct NodeLabel: View {
    let component: PathComponent?
    let value: JSONValue
    let path: ValuePath
    let errors: [SchemaValidationError]

    var body: some View {
        HStack(spacing: 6) {
            switch component {
            case .key(let key):
                Text(key)
                    .foregroundStyle(Color(nsColor: Theme.key))
                    .fontWeight(.medium)
                Text(":").foregroundStyle(.tertiary)
            case .index(let index):
                Text(String(index)).foregroundStyle(.secondary)
                Text(":").foregroundStyle(.tertiary)
            case nil:
                Text("$").foregroundStyle(.secondary)
            }

            valueText
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if !errors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(errors.map(\.message).joined(separator: "\n"))
            }

            if value.isContainer {
                Text("\(value.childCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .help(path.jsonPathString)
    }

    @ViewBuilder
    private var valueText: some View {
        switch value {
        case .object(let object):
            Text(object.isEmpty ? "{}" : "{ … }").foregroundStyle(.secondary)
        case .array(let array):
            Text(array.isEmpty ? "[]" : "[ … ]").foregroundStyle(.secondary)
        case .string(let string):
            Text(verbatim: "\"\(string.replacingOccurrences(of: "\n", with: "⏎"))\"")
                .foregroundStyle(Theme.color(for: value))
        case .number(let number):
            Text(number.literal).foregroundStyle(Theme.color(for: value))
        case .bool(let bool):
            Text(bool ? "true" : "false").foregroundStyle(Theme.color(for: value))
        case .null:
            Text("null").foregroundStyle(Theme.color(for: value)).italic()
        }
    }
}

struct NodeContextMenu: View {
    let value: JSONValue
    let path: ValuePath
    @Environment(AppModel.self) private var model

    private var isArrayElement: Bool { path.last?.index != nil }
    private var isObjectMember: Bool { path.last?.key != nil }

    var body: some View {
        Button("Copy Value") { model.copyValue(at: path) }
        Button("Copy Path") { model.copyPath(path) }
        Button("Copy JSON Pointer") { model.copyPointer(path) }
        if case .key(let key)? = path.last {
            Button("Copy Key") { model.copyToPasteboard(key) }
        }
        Button("Query This Path") { model.queryFromTree(path) }

        Divider()

        Button("Edit Value…") { model.beginEditValue(at: path) }
        if isObjectMember {
            Button("Rename Key…") { model.beginRenameKey(at: path) }
        }

        if case .array(let elements) = value {
            Divider()
            Button("Add Item") { model.addArrayItem(to: path) }
            if !elements.isEmpty {
                Button("Infer Item Schema") { model.inferSchemaFromArray(at: path) }
            }
        }
        if case .object = value {
            Divider()
            Button("Add Property…") { model.beginAddProperty(to: path) }
        }

        if !path.isRoot {
            Divider()
            if isArrayElement, let parent = path.parent, let index = path.last?.index {
                Button("Insert Item After") { model.addArrayItem(to: parent, after: index) }
            }
            Button("Duplicate") { model.duplicate(at: path) }
            Button("Delete", role: .destructive) { model.remove(at: path) }
        }

        if value.isContainer {
            Divider()
            Button("Expand All Below") { model.expandAll(below: path) }
            Button("Collapse All Below") { model.collapseAll(below: path) }
        }
    }
}

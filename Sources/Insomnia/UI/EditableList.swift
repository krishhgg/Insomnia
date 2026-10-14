import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a list's search field matches: every word of the query appears
/// somewhere in one of the item's fields, ignoring case and accents.
/// Anywhere in the field, not only at a word's start, so "claude" finds
/// com.anthropic.claudefordesktop.
enum ListFilter {
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fields.map(fold)
        return words.allSatisfy { w in haystack.contains { $0.contains(w) } }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// An editable list in a Settings section: a search field that filters the
/// rows, a + button beside it that opens `adder` in a popover, then the
/// rows. Each part is its own Form row.
struct EditableList<Item: Hashable, Row: View, Adder: View>: View {
    let items: [Item]
    let searchPrompt: String
    let addHelp: String
    let emptyText: String
    let fields: (Item) -> [String]
    let row: (Item) -> Row
    /// The popover's content; it calls `done` to close the popover.
    let adder: (_ done: @escaping () -> Void) -> Adder

    @State private var query = ""
    @State private var adding = false

    init(
        _ items: [Item],
        searchPrompt: String,
        addHelp: String,
        emptyText: String,
        fields: @escaping (Item) -> [String],
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder adder: @escaping (_ done: @escaping () -> Void) -> Adder
    ) {
        self.items = items
        self.searchPrompt = searchPrompt
        self.addHelp = addHelp
        self.emptyText = emptyText
        self.fields = fields
        self.row = row
        self.adder = adder
    }

    var body: some View {
        HStack(spacing: DesignTokens.Space.m) {
            ListSearchField(text: $query, prompt: searchPrompt)
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 14, height: 14)
            }
            .help(addHelp)
            .accessibilityLabel(addHelp)
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                adder { adding = false }
            }
        }
        let shown = items.filter { ListFilter.matches(query, fields($0)) }
        if items.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        } else if shown.isEmpty {
            Text("Nothing matches \u{201C}\(query)\u{201D}").foregroundStyle(.secondary)
        }
        ForEach(shown, id: \.self) { item in
            row(item)
        }
    }
}

/// AppKit's search field, for its magnifying glass and clear button.
/// Return runs `onSubmit`; `focusOnAppear` puts the cursor in it once it
/// is in a window (a popover's field).
struct ListSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var focusOnAppear = false
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.placeholderString = prompt
        field.focusWhenShown = focusOnAppear
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: FocusingSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ListSearchField

        init(parent: ListSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }

    final class FocusingSearchField: NSSearchField {
        var focusWhenShown = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusWhenShown, window != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

/// A popover that adds one line of text: a preset or a tmux target.
struct TextEntryAdder: View {
    let title: String
    let placeholder: String
    var monospaced = false
    var note: String?
    let canAdd: (String) -> Bool
    /// Adds the text and returns nil, or returns why it cannot be added.
    let add: (String) -> String?
    let done: () -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: text) { error = nil }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd(text))
            }
        }
        .padding(DesignTokens.Space.xl)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func submit() {
        guard canAdd(text) else { return }
        if let problem = add(text) {
            error = problem
        } else {
            done()
        }
    }
}

// MARK: Apps

/// An app found on disk: what the picker lists.
struct InstalledApp: Hashable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }
}

/// The apps the + button offers: every app in /Applications,
/// ~/Applications and /System/Applications (and folders one level inside
/// them, such as Utilities), plus running apps that live anywhere else.
enum InstalledApps {
    static var folders: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
        ]
    }

    /// Reads the folders off the main actor. `extra` (running apps) fills
    /// in what the folders lack; the first app found for a bundle id wins.
    @concurrent
    static func scan(extra: [InstalledApp], excluding selfID: String) async -> [InstalledApp] {
        var found: [InstalledApp] = []
        for folder in folders {
            collect(in: folder, depth: 0, into: &found)
        }
        return merged(found + extra, excluding: selfID)
    }

    /// Running apps with a bundle on disk, as the picker's `extra`.
    @MainActor
    static func running() -> [InstalledApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let url = app.bundleURL, url.pathExtension == "app" else { return nil }
            return InstalledApp(bundleID: id, name: app.localizedName ?? displayName(at: url), url: url)
        }
    }

    private static func collect(in folder: URL, depth: Int, into found: inout [InstalledApp]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for url in entries {
            if url.pathExtension == "app" {
                if let app = app(at: url) { found.append(app) }
            } else if depth == 0,
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isPackage != true {
                collect(in: url, depth: depth + 1, into: &found)
            }
        }
    }

    static func app(at url: URL) -> InstalledApp? {
        let plist = url.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return app(info: info, url: url, name: displayName(at: url))
    }

    /// An app from its Info.plist; nil without a bundle id.
    static func app(info: [String: Any], url: URL, name: String) -> InstalledApp? {
        guard let id = info["CFBundleIdentifier"] as? String,
              !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return InstalledApp(bundleID: id, name: name, url: url)
    }

    /// The name Finder shows, without ".app".
    static func displayName(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// One app per bundle id (the first, ignoring case), not `selfID`, by name.
    static func merged(_ apps: [InstalledApp], excluding selfID: String) -> [InstalledApp] {
        var seen: Set<String> = [selfID.lowercased()]
        var out: [InstalledApp] = []
        for app in apps where seen.insert(app.bundleID.lowercased()).inserted {
            out.append(app)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The apps `query` finds by name or bundle id: names that start with
    /// it first, then names that contain it, then bundle id matches, each
    /// group in the order given.
    static func search(_ apps: [InstalledApp], _ query: String) -> [InstalledApp] {
        let q = ListFilter.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return apps }
        func rank(_ app: InstalledApp) -> Int? {
            let name = ListFilter.fold(app.name)
            if name.hasPrefix(q) { return 0 }
            if name.contains(q) { return 1 }
            if ListFilter.matches(query, [app.name, app.bundleID]) { return 2 }
            return nil
        }
        return apps.enumerated()
            .compactMap { i, app in rank(app).map { (rank: $0, index: i, app: app) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.app)
    }

    /// `query` as a bundle id to add by hand: shaped like one
    /// (com.example.app) and not one of `known`, ignoring case.
    static func manualBundleID(_ query: String, known: [String]) -> String? {
        let id = query.trimmingCharacters(in: .whitespaces)
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              !known.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
        return id
    }

    /// The name to show for a listed bundle id: the running app's, the
    /// installed app's, or the id's last part when neither is found.
    @MainActor
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return displayName(at: url)
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// App icons by path, and the generic app icon for an id with no app.
@MainActor
enum AppIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(at url: URL?) -> NSImage {
        guard let url else { return generic }
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    static var generic: NSImage { NSWorkspace.shared.icon(for: .applicationBundle) }
}

/// A listed app: its icon, its name and its bundle id, noting an id with
/// no app installed.
struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: DesignTokens.Space.m) {
            Image(nsImage: AppIcons.icon(at: url))
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(url == nil ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(InstalledApps.displayName(for: bundleID))
                Text(url == nil ? "\(bundleID) \u{00B7} not installed" : bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The + popover for an app list: installed apps with their icons,
/// searchable by name or bundle id, and a row that adds a typed bundle id
/// no installed app has. Picking a row adds it and closes the popover;
/// Return picks the first row.
struct AppPicker: View {
    let added: [String]
    let add: (String) -> Void
    let done: () -> Void

    @State private var query = ""
    @State private var apps: [InstalledApp]?

    private var results: [InstalledApp] { InstalledApps.search(apps ?? [], query) }

    private var manualID: String? {
        InstalledApps.manualBundleID(query, known: (apps ?? []).map(\.bundleID) + added)
    }

    var body: some View {
        VStack(spacing: 0) {
            ListSearchField(text: $query, prompt: "App name or bundle identifier", focusOnAppear: true, onSubmit: pickFirst)
                .padding(DesignTokens.Space.l)
            Divider()
            list
        }
        .frame(width: 360, height: 420)
        .task {
            let selfID = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
            apps = await InstalledApps.scan(extra: InstalledApps.running(), excluding: selfID)
        }
    }

    @ViewBuilder
    private var list: some View {
        if apps == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty, manualID == nil {
            ContentUnavailableView {
                Label("No apps found", systemImage: "magnifyingglass")
            } description: {
                Text("Type a full bundle identifier, such as com.example.app, to add an app that is not installed.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let manualID {
                        Button { pick(manualID) } label: {
                            row(icon: AppIcons.generic, title: "Add \u{201C}\(manualID)\u{201D}", subtitle: "Bundle identifier, not installed")
                        }
                    }
                    ForEach(results) { app in
                        let isAdded = added.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
                        Button { pick(app.bundleID) } label: {
                            row(icon: AppIcons.icon(at: app.url), title: app.name, subtitle: app.bundleID, added: isAdded)
                        }
                        .disabled(isAdded)
                    }
                }
                .buttonStyle(PickerRowStyle())
                .padding(DesignTokens.Space.s)
            }
        }
    }

    private func row(icon: NSImage, title: String, subtitle: String, added: Bool = false) -> some View {
        HStack(spacing: DesignTokens.Space.m) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if added {
                Text("Added").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(added ? 0.55 : 1)
    }

    private func pickFirst() {
        if let manualID {
            pick(manualID)
        } else if let first = results.first(where: { app in
            !added.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
        }) {
            pick(first.bundleID)
        }
    }

    private func pick(_ id: String) {
        add(id)
        done()
    }
}

/// A full-width picker row with a fill under the pointer.
private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PickerRow(configuration: configuration)
    }

    private struct PickerRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Hover.radius, style: .continuous)
            let fill = !isEnabled ? 0 : configuration.isPressed ? DesignTokens.Hover.pressedFill : hovering ? DesignTokens.Hover.fill : 0
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Space.m)
                .padding(.vertical, DesignTokens.Space.xs)
                .background(shape.fill(Color.primary.opacity(fill)))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .transaction { $0.animation = nil }
        }
    }
}

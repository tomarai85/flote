import AppKit
import SwiftUI

// S7-1: global search — THE table-stakes gap (competitive matrix claimed
// 検索=有; the code had none). A Spotlight-style palette: global hotkey →
// type → live matches across every note (open panels AND Groups-archived)
// → Enter/click opens the note as a floating panel.
//
// The palette panel is nonactivating (same discipline as note panels): it
// takes key status for typing without activating Flote, so the app the
// user was in stays frontmost and Esc returns them exactly where they were.

// MARK: - Matching

struct SearchHit: Identifiable {
    let id: UUID          // note id
    let title: String
    let snippet: String
    let isOpen: Bool
    let score: Int
}

enum NoteSearch {

    /// Case-insensitive substring scan over title + body, JP-safe.
    /// Scoring: title prefix > title contains > body contains; open panels
    /// nudge above archived so visible work surfaces first. Pure logic —
    /// unit-testable without AppKit.
    @MainActor
    static func search(_ rawQuery: String, in notes: [StickyNote]) -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for note in notes {
            let title = note.lockedSafeTitle ?? ""
            var score = 0
            if !title.isEmpty {
                if title.range(of: query, options: [.caseInsensitive, .anchored]) != nil {
                    score = 100
                } else if title.range(of: query, options: .caseInsensitive) != nil {
                    score = 60
                }
            }
            // S6 lock seal, FULL form (Evaluator r3 #1): a locked note is
            // findable by its EXPLICIT title only — its body is never
            // matched and never rendered into a snippet. An unlocked note
            // matches title or body as usual.
            if note.isLocked {
                guard score > 0, note.rolledTitle?.isEmpty == false else { continue }
                hits.append(SearchHit(
                    id: note.id,
                    title: displayableTitle(note),
                    snippet: L("ロック中（Touch ID で開きます）", "Locked (opens with Touch ID)"),
                    isOpen: note.isPanelOpen,
                    score: score + (note.isPanelOpen ? 5 : 0)
                ))
                continue
            }
            let body = note.text
            if score == 0, body.range(of: query, options: .caseInsensitive) != nil {
                score = 30
            }
            guard score > 0 else { continue }
            if note.isPanelOpen { score += 5 }
            hits.append(SearchHit(
                id: note.id,
                title: displayableTitle(note),
                snippet: snippet(around: query, in: body),
                isOpen: note.isPanelOpen,
                score: score
            ))
        }
        return hits.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.title < b.title
        }
    }

    /// Locked notes never leak body text into results (S6 lock seal).
    @MainActor
    private static func displayableTitle(_ note: StickyNote) -> String {
        if note.isLocked, note.rolledTitle?.isEmpty != false {
            return L("ロック中のノート", "Locked note")
        }
        if let t = note.lockedSafeTitle, !t.isEmpty { return t }
        let first = note.text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return first.isEmpty ? "無題" : String(first.prefix(40))
    }

    static func snippet(around query: String, in body: String) -> String {
        guard let r = body.range(of: query, options: .caseInsensitive) else {
            let flat = body.replacingOccurrences(of: "\n", with: " ")
            return String(flat.prefix(64))
        }
        let start = body.index(r.lowerBound, offsetBy: -24, limitedBy: body.startIndex)
            ?? body.startIndex
        let end = body.index(r.upperBound, offsetBy: 40, limitedBy: body.endIndex)
            ?? body.endIndex
        return String(body[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Window controller

@MainActor
final class SearchPaletteController: NSObject, NSWindowDelegate {
    static let shared = SearchPaletteController()

    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        // Center on the screen the mouse is on — the palette should appear
        // where the user is looking, not where the last note was.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: vf.midX - size.width / 2,
                y: vf.minY + vf.height * 0.62 - size.height / 2
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        // Borderless nonactivating panels win key status asynchronously;
        // hand the first-responder to the SwiftUI content once that settles
        // or the FocusState assert fires into a not-yet-key window.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, let content = panel.contentView else { return }
            panel.makeFirstResponder(content)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let p = SearchKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.hasShadow = true

        let host = NSHostingView(rootView: SearchPaletteView(
            onClose: { [weak self] in self?.close() }
        ))
        host.sizingOptions = []  // same discipline as FloatingPanel
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.frame = NSRect(origin: .zero, size: p.frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        // Spotlight behavior: clicking anywhere else (the palette loses
        // key) dismisses it — it must never squat over the user's work
        // (live-fire 2026-07-11: a stuck palette sat on Tom's terminal).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    private var resignObserver: NSObjectProtocol?
}

/// Borderless NSWindows refuse key status by default — the palette must
/// take key or the TextField never receives a keystroke.
private final class SearchKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI palette

struct SearchPaletteView: View {
    var onClose: () -> Void

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool

    private let ink = Color(red: 0.24, green: 0.20, blue: 0.15)
    private let amber = Color(red: 0.85, green: 0.62, blue: 0.13)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ink.opacity(0.45))
                TextField(L("ノートを検索…", "Search notes…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .foregroundColor(ink)
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
                if !query.isEmpty {
                    Text("\(hits.count)")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundColor(ink.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if !hits.isEmpty {
                Divider().opacity(0.4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                resultRow(hit, isSelected: index == selected)
                                    .id(index)
                                    .onTapGesture { open(hit) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 252)
                    .onChange(of: selected) { _, new in
                        proxy.scrollTo(new)
                    }
                }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider().opacity(0.4)
                Text(L("見つかりませんでした", "No matches"))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(ink.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.993, green: 0.972, blue: 0.930))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            query = ""
            hits = []
            selected = 0
            // Double-assert: once now, once after the window's async key
            // grant — a single immediate set loses the race and leaves the
            // field deaf (caught by live-fire 2026-07-11).
            fieldFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                fieldFocused = true
            }
        }
        .onChange(of: query) { _, q in
            hits = NoteSearch.search(q, in: NoteManager.shared.notes)
            selected = 0
        }
        .onKeyPress(.downArrow) {
            if selected < hits.count - 1 { selected += 1 }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selected > 0 { selected -= 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private func resultRow(_ hit: SearchHit, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.isOpen ? "note.text" : "archivebox")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? amber : ink.opacity(0.35))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(ink)
                    .lineLimit(1)
                Text(hit.snippet)
                    .font(.system(size: 11))
                    .foregroundColor(ink.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? amber.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func openSelected() {
        guard hits.indices.contains(selected) else { return }
        open(hits[selected])
    }

    /// Same open-or-focus path as the menu-bar recents / Groups tab.
    private func open(_ hit: SearchHit) {
        onClose()
        if PanelManager.shared.hasPanel(noteID: hit.id) {
            PanelManager.shared.focusPanel(noteID: hit.id)
        } else {
            NoteManager.shared.openPanel(noteID: hit.id)
            if let updated = NoteManager.shared.note(byID: hit.id) {
                PanelManager.shared.createPanel(for: updated)
            }
        }
    }
}

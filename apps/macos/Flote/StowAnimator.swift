import AppKit

// StowAnimator handles roll-up and mini animations for FloatingPanel instances.
// All methods run on the main actor since they manipulate NSWindow frames directly.
//
// Architecture note (2026-04-17): After four SIGABRT crashes in
// NSHostingView.updateAnimatedWindowSize → _postWindowNeedsLayout recursion
// (ips: 132651, 155547, 181410, 181956), we abandoned panel.animator().setFrame
// for shrinking transitions. The new approach:
//
//   1. Snapshot the NSPanel's SwiftUI-backed contentView into an NSImage.
//   2. Spin up a transient, snapshot-only NSPanel (pure AppKit, no
//      NSHostingView) and animate its frame.
//   3. Instantly resize the real panel (animate: false) and swap it back on.
//
// This completely side-steps the AppKit/SwiftUI bridge feedback loop that
// caused the crashes, because the animated window has no NSHostingView to
// fire windowDidLayout → updateAnimatedWindowSize from.
//
// Growing transitions (expand / expandFromMini / miniToRolledUp) don't take
// a snapshot because the target size's SwiftUI content has never rendered
// yet — any snapshot would misrepresent the result. They snap instantly.
@MainActor
final class StowAnimator {

    static let shared = StowAnimator()
    private init() {}

    // Height of the rolled-up state: matches PaperCurlView max (18+8=26).
    private let rolledUpHeight: CGFloat = 26
    // Size of the panel in mini mode.
    private let miniSize: CGFloat = 48
    // Animation duration in seconds.
    private let duration: TimeInterval = 0.3

    // MARK: - Roll-up (in place, upward)

    /// Roll up the note in place. The top-left corner stays fixed,
    /// the width is preserved, and the height shrinks to `rolledUpHeight`.
    /// The visual effect is a scroll rolling upward from the bottom.
    func rollUp(panel: FloatingPanel, noteID: UUID) {
        let currentFrame = panel.frame
        NoteManager.shared.saveExpandedGeometry(
            id: noteID,
            size: currentFrame.size,
            position: currentFrame.origin
        )

        let topY = currentFrame.maxY
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: topY - rolledUpHeight,
            width: currentFrame.width,
            height: rolledUpHeight
        )

        animateShrinkWithSnapshot(panel: panel, to: targetFrame, noteID: noteID) {
            NoteManager.shared.updateStowState(id: noteID, state: .rolledUp)
        }
    }

    // Animate the panel back to its original size from rolled-up state.
    func expand(panel: FloatingPanel, noteID: UUID) {
        guard let note = NoteManager.shared.note(byID: noteID) else { return }

        let targetSize = note.expandedSize ?? GoldenRatio.medium
        let topY = panel.frame.maxY
        let targetFrame = NSRect(
            x: panel.frame.minX,
            y: topY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )

        snapTo(panel: panel, targetFrame: targetFrame, noteID: noteID, finalState: .expanded)
    }

    // MARK: - Mini mode

    // Shrink the panel to a 48x48 dot anchored at its current top-left corner.
    func shrinkToMini(panel: FloatingPanel, noteID: UUID) {
        let currentFrame = panel.frame
        NoteManager.shared.saveExpandedGeometry(
            id: noteID,
            size: currentFrame.size,
            position: currentFrame.origin
        )

        let topY = currentFrame.maxY
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: topY - miniSize,
            width: miniSize,
            height: miniSize
        )

        animateShrinkWithSnapshot(panel: panel, to: targetFrame, noteID: noteID) {
            NoteManager.shared.updateStowState(id: noteID, state: .mini)
        }
    }

    // Expand a mini panel back to its full size.
    func expandFromMini(panel: FloatingPanel, noteID: UUID) {
        guard let note = NoteManager.shared.note(byID: noteID) else { return }

        let targetSize = note.expandedSize ?? GoldenRatio.medium
        let topY = panel.frame.maxY
        let targetFrame = NSRect(
            x: panel.frame.minX,
            y: topY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        snapTo(panel: panel, targetFrame: targetFrame, noteID: noteID, finalState: .expanded)
    }

    // MARK: - Direct rolledUp ↔ mini transitions (M4)

    /// Transition directly from rolledUp to mini without an intermediate expand.
    func rollUpToMini(panel: FloatingPanel, noteID: UUID) {
        let topY = panel.frame.maxY
        let targetFrame = NSRect(
            x: panel.frame.minX,
            y: topY - miniSize,
            width: miniSize,
            height: miniSize
        )
        animateShrinkWithSnapshot(panel: panel, to: targetFrame, noteID: noteID) {
            NoteManager.shared.updateStowState(id: noteID, state: .mini)
        }
    }

    /// Transition directly from mini to rolledUp without an intermediate expand.
    func miniToRolledUp(panel: FloatingPanel, noteID: UUID) {
        guard let note = NoteManager.shared.note(byID: noteID) else { return }
        let expandedWidth = note.expandedSize?.width ?? GoldenRatio.medium.width
        let topY = panel.frame.maxY
        let targetFrame = NSRect(
            x: panel.frame.minX,
            y: topY - rolledUpHeight,
            width: expandedWidth,
            height: rolledUpHeight
        )
        snapTo(panel: panel, targetFrame: targetFrame, noteID: noteID, finalState: .rolledUp)
    }

    // MARK: - Private helpers

    /// Instant frame change with SwiftUI state swap. Used for growing
    /// transitions where there's no pre-rendered target content to snapshot.
    /// No animator() → no NSHostingView recursion → no crash.
    private func snapTo(
        panel: FloatingPanel,
        targetFrame: NSRect,
        noteID: UUID,
        finalState: StowState
    ) {
        PanelManager.shared.beginAnimating(noteID: noteID)
        // Update SwiftUI state FIRST so the growing view renders at the
        // correct target size when the frame changes.
        NoteManager.shared.updateStowState(id: noteID, state: finalState)
        panel.setFrame(targetFrame, display: true, animate: false)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PanelManager.shared.endAnimating(noteID: noteID)
            }
        }
    }

    /// Snapshot-based shrink animation. Avoids panel.animator().setFrame on
    /// the real panel (which triggers NSHostingView.updateAnimatedWindowSize
    /// recursion on macOS 26) by animating a transient snapshot-only panel
    /// instead. The real panel is resized instantly once the animation ends.
    private func animateShrinkWithSnapshot(
        panel: FloatingPanel,
        to targetFrame: NSRect,
        noteID: UUID,
        onFinish: @escaping @MainActor () -> Void
    ) {
        let startFrame = panel.frame

        // Take an NSImage snapshot of the real panel's contents. If snapshot
        // fails for any reason, fall back to instant snap.
        guard let contentView = panel.contentView else {
            panel.setFrame(targetFrame, display: true, animate: false)
            onFinish()
            return
        }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            panel.setFrame(targetFrame, display: true, animate: false)
            onFinish()
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(rep)

        // Build a throwaway panel that only contains a plain NSView drawing
        // the snapshot. No SwiftUI, no NSHostingView → animator().setFrame
        // can't trigger the updateAnimatedWindowSize crash path.
        let transient = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        transient.isOpaque = false
        transient.backgroundColor = .clear
        transient.hasShadow = true
        transient.level = panel.level
        transient.ignoresMouseEvents = true
        transient.collectionBehavior = panel.collectionBehavior

        let snap = SnapshotView(frame: NSRect(origin: .zero, size: startFrame.size))
        snap.image = snapshot
        snap.wantsLayer = true
        snap.layer?.cornerRadius = 12
        snap.layer?.masksToBounds = true
        snap.autoresizingMask = [.width, .height]
        transient.contentView = snap

        PanelManager.shared.beginAnimating(noteID: noteID)
        // Hide the real panel so the transient is what the user sees during
        // the animation. orderOut (not close) preserves the window object.
        panel.orderOut(nil)
        transient.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            transient.animator().setFrame(targetFrame, display: true)
        }, completionHandler: {
            // Hop to the next runloop so AppKit's layout settle on the
            // transient has fully finished before we swap the real panel in.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Swap SwiftUI state first, then resize the real panel
                    // instantly (no animator → no hosting-view recursion).
                    onFinish()
                    // If a background Organize / AI Sort completed DURING
                    // the stow animation and triggered removePanel (e.g.
                    // classify routed this note to another group and
                    // closed its panel), don't resurrect the panel. Leave
                    // it removed and just tear down the transient.
                    if PanelManager.shared.hasPanel(noteID: noteID) {
                        panel.setFrame(targetFrame, display: true, animate: false)
                        panel.orderFrontRegardless()
                    }
                    transient.orderOut(nil)
                    PanelManager.shared.endAnimating(noteID: noteID)
                }
            }
        })
    }
}

/// Plain NSView that draws an NSImage anchored to the TOP of its bounds.
/// As the containing window shrinks during a roll-up animation, the view
/// shrinks too — with top-anchored drawing, the bottom of the snapshot
/// gets clipped, producing a natural "scroll rolling up" visual. When the
/// view grows (reverse direction), the bottom reveals — but growing paths
/// use snapTo(), not this view.
private final class SnapshotView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        let imageSize = image.size
        // macOS coords: y=0 is bottom. Anchor image's top to view's top
        // by placing its origin at (bounds.height - imageSize.height).
        // When bounds.height < imageSize.height, the origin goes negative
        // and the bottom of the image extends below the view — clipped
        // by the layer's masksToBounds + clipsToBounds, giving the
        // roll-up effect.
        let origin = NSPoint(x: 0, y: bounds.height - imageSize.height)
        image.draw(
            at: origin,
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1.0
        )
    }
}

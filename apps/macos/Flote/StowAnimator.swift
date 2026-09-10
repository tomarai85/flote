import AppKit

// StowAnimator handles stow (balloon handle) and mini transitions for
// FloatingPanel instances. All methods run on the main actor since they
// manipulate NSWindow frames directly.
//
// Architecture note (2026-04-17): After four SIGABRT crashes in
// NSHostingView.updateAnimatedWindowSize → _postWindowNeedsLayout recursion
// (ips: 132651, 155547, 181410, 181956), we NEVER animate the real panel's
// FRAME. Two safe tools remain:
//
//   1. alphaValue animation on the real panel (window opacity — no layout
//      pass, proven safe; frame changes happen instantly while invisible).
//   2. For the mini shrink only: a transient, snapshot-only NSPanel (pure
//      AppKit, no NSHostingView) whose frame IS animated, then the real
//      panel snaps in at the end (animateShrinkWithSnapshot).
//
// Stow redesign (2026-07-12, owner verdict): the balloon FLIGHT is gone —
// 「巻き取るというより、シンプルに消えるイメージ」. Stow = the note fades
// out IN PLACE and a small balloon handle appears at its former top edge;
// restore = the note fades in just below the handle. No transient panels,
// no snapshot cache, no cross-screen travel on this path anymore.
@MainActor
final class StowAnimator {

    static let shared = StowAnimator()
    private init() {}

    // Handle window size while stowed. The persisted state stays
    // `.rolledUp` (same raw value — zero migration); only geometry and
    // rendering changed across the redesigns.
    static let stringSize = CGSize(width: 44, height: 76)
    // Size of the panel in mini mode.
    private let miniSize: CGFloat = 48
    // Mini shrink animation duration in seconds.
    private let duration: TimeInterval = 0.3
    // Stow fades (2026-07-12): note out / handle+note in. Short — the
    // owner wants "simply disappears", not choreography.
    private let fadeOutDuration: TimeInterval = 0.15
    private let fadeInDuration: TimeInterval = 0.15
    private let handleFadeInDuration: TimeInterval = 0.12

    /// Handle frame LOCAL to the note (2026-07-12 redesign): same
    /// x-center, the balloon (bottom ~24pt of the window) hovering at the
    /// note's former TOP edge — never at the screen top. Clamped onto the
    /// visible area, nudged sideways while it overlaps another handle.
    private func handleFrame(for noteFrame: NSRect, on screen: NSScreen?, noteID: UUID) -> NSRect {
        let vf = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.stringSize
        var x = min(max(noteFrame.midX - size.width / 2, vf.minX + 8),
                    vf.maxX - size.width - 8)
        let y = min(max(noteFrame.maxY - 24, vf.minY + 8),
                    vf.maxY - size.height)
        var frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        // Collision nudge at LOCAL positions (notes are spread out, so a
        // rect-overlap check replaces the old shared-top-edge row logic).
        let others = PanelManager.shared.stringPanelFrames(excluding: noteID)
        var attempts = 0
        while attempts < 40,
              others.contains(where: { $0.insetBy(dx: -8, dy: -8).intersects(frame) }) {
            x += size.width + 12
            if x + size.width > vf.maxX - 8 { x = vf.minX + 8 + CGFloat(attempts) * 6 }
            frame.origin.x = x
            attempts += 1
        }
        return frame
    }

    // MARK: - Stow (fade out in place → balloon handle)

    /// Stow: the note fades out IN PLACE (alpha only — the real panel's
    /// frame is NEVER animated), then the panel re-dresses as the balloon
    /// handle at the note's former top edge and quickly fades back in.
    /// Reduce Motion = instant state change, no fades.
    func rollUp(panel: FloatingPanel, noteID: UUID) {
        let currentFrame = panel.frame
        NoteManager.shared.saveExpandedGeometry(
            id: noteID,
            size: currentFrame.size,
            position: currentFrame.origin
        )
        let target = handleFrame(
            for: currentFrame, on: panel.screen, noteID: noteID)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            snapTo(panel: panel, targetFrame: target, noteID: noteID, finalState: .rolledUp)
            return
        }

        PanelManager.shared.beginAnimating(noteID: noteID)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Removed mid-fade (a background classify closed it)?
                    // Leave it removed — just release the animation guard.
                    guard PanelManager.shared.hasPanel(noteID: noteID) else {
                        PanelManager.shared.endAnimating(noteID: noteID)
                        return
                    }
                    // Re-dress invisible: state swap + INSTANT frame change
                    // while alpha 0 (the proven crash-safe pattern), then a
                    // quick fade-in of the handle.
                    NoteManager.shared.updateStowState(id: noteID, state: .rolledUp)
                    panel.applyChrome(for: .rolledUp)
                    panel.setFrame(target, display: true, animate: false)
                    panel.alphaValue = 0
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = self.handleFadeInDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 1.0
                    }, completionHandler: {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if PanelManager.shared.hasPanel(noteID: noteID) {
                                    panel.alphaValue = 1.0
                                }
                                PanelManager.shared.endAnimating(noteID: noteID)
                            }
                        }
                    })
                }
            }
        })
    }

    // MARK: - Restore (fade in just below the handle)

    /// Tap the balloon: the note fades in JUST BELOW the handle — top
    /// edge ≈ handle bottom − 8pt, same x-center, clamped on-screen — NOT
    /// at its historical frame (owner 2026-07-12: flying back to the old
    /// position was wrong). The new spot is persisted explicitly because
    /// the didMove observer is suppressed while the animation guard is up.
    func expand(panel: FloatingPanel, noteID: UUID) {
        guard let note = NoteManager.shared.note(byID: noteID) else { return }

        let handleF = panel.frame
        let targetSize = note.expandedSize ?? GoldenRatio.medium
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(
            x: handleF.midX - targetSize.width / 2,
            y: handleF.minY - 8 - targetSize.height
        )
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - targetSize.width))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - targetSize.height))
        let targetFrame = NSRect(origin: origin, size: targetSize)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            snapTo(panel: panel, targetFrame: targetFrame, noteID: noteID, finalState: .expanded)
            NoteManager.shared.updatePosition(id: noteID, position: origin)
            NoteManager.shared.updateSize(id: noteID, size: targetSize)
            return
        }

        PanelManager.shared.beginAnimating(noteID: noteID)
        // Re-dress invisible, place instantly, fade in. applyChrome
        // restores the user's opacity-slider alpha — capture it as the
        // fade target, then start from 0.
        NoteManager.shared.updateStowState(id: noteID, state: .expanded)
        panel.applyChrome(for: .expanded)
        let targetAlpha = panel.alphaValue
        panel.alphaValue = 0
        panel.setFrame(targetFrame, display: true, animate: false)
        NoteManager.shared.updatePosition(id: noteID, position: origin)
        NoteManager.shared.updateSize(id: noteID, size: targetSize)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = targetAlpha
        }, completionHandler: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if PanelManager.shared.hasPanel(noteID: noteID) {
                        panel.alphaValue = targetAlpha
                    }
                    PanelManager.shared.endAnimating(noteID: noteID)
                }
            }
        })
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

    /// Transition directly from the string to mini without an intermediate
    /// expand. The string is tiny — instant snap reads cleaner than a shrink.
    func rollUpToMini(panel: FloatingPanel, noteID: UUID) {
        let targetFrame = NSRect(
            x: panel.frame.midX - miniSize / 2,
            y: panel.frame.maxY - miniSize,
            width: miniSize,
            height: miniSize
        )
        snapTo(panel: panel, targetFrame: targetFrame, noteID: noteID, finalState: .mini)
    }

    /// Transition directly from mini to the balloon handle without an
    /// intermediate expand. The handle appears local to the mini (2026-07-12
    /// redesign: handles live where their note lived, never at screen top).
    func miniToRolledUp(panel: FloatingPanel, noteID: UUID) {
        let targetFrame = handleFrame(
            for: panel.frame, on: panel.screen, noteID: noteID)
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
        panel.applyChrome(for: finalState)
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

        // Accessibility: 視差効果を減らす — no shrink animation, just the
        // instant state change (same path as the snapshot-failure fallback).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(targetFrame, display: true, animate: false)
            onFinish()
            return
        }

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
        // S3: behind-window vibrancy is a compositor effect that cacheDisplay
        // cannot capture — the raw rep has a transparent hole where the frost
        // was. Compose the note's SOLID theme background under the cached
        // content so the roll-up never flashes see-through.
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.lockFocus()
        let spec = AppearanceSettings.shared.appThemeSpec
            ?? FloteThemeRegistry.specForLegacy(
                NoteManager.shared.note(byID: noteID)?.colorTheme.rawValue ?? "yellow")
        // Light-pinned to match NoteView (notes are paper, always light) —
        // following effectiveAppearance here painted the DARK variant under
        // the light note during the shrink = dark flash (Evaluator #4).
        let bg = spec.palette(dark: false).background
        NSColor(srgbRed: bg.red, green: bg.green, blue: bg.blue, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: contentView.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: contentView.bounds.size))
        snapshot.unlockFocus()

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
        // Captured ONCE at flight start — constant for the entire animation
        // (the invariant is "never varies DURING an animation"; the Settings
        // apply path is gated off animating panels, so it cannot move here).
        snap.layer?.cornerRadius = AppearanceSettings.shared.cornerRadius
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
/// As the containing window shrinks during the mini transition, the view
/// shrinks too — with top-anchored drawing, the bottom of the snapshot
/// gets clipped, producing a natural "scroll rolling up" visual. Used
/// ONLY by animateShrinkWithSnapshot (the stow path stopped flying
/// entirely — 2026-07-12 redesign — so the scale-to-fit mode is gone).
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

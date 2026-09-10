import SwiftUI
import AppKit
@preconcurrency import UserNotifications

// S10 timers (antinote-behavior-specs.md §7): a note whose FIRST LINE is the
// `timer` / `タイマー` token becomes a timer note — a narrow TimerRail runs
// down the note's LEFT MARGIN (Antinote's real layout, spec Appendix C)
// while the text beside it stays a normal editable note (meeting notes
// WHILE the timer runs is the use case).
//
//   timer            → stopwatch (counts up)
//   timer 5          → 5-minute countdown (fractional ok: 3.5)
//   timer 5: 集中    → countdown with a title shown in the bar
//   timer 25 5       → pomodoro (25 work / 5 break, endless cycles)
//
// Deviations from Antinote (deliberate, v1):
//   - First line only (Antinote: any line start) — per the Flote mapping.
//   - No `3:30` mm:ss form — the colon is the TITLE separator here;
//     fractional minutes (3.5) cover sub-minute needs.
//   - No `timer p/r/s/0/pomo` control words — the bar has explicit
//     play/pause and stop buttons instead.
//   - No menu-bar remaining time, no full-screen takeover, no non-skip
//     streak bookkeeping (spec marks streaks v2).
//
// State is IN-MEMORY per note id (TimerEngine singleton). It survives panel
// close/reopen within the session; app relaunch = timer gone. A running
// timer keeps running with the panel closed, and its finish cue (sound +
// user notification) still fires — only the border pulse needs a live view.

// S10-TIMER-PURE-BEGIN
// Pure timer core — Foundation-only, no timers, no AppKit. Everything is a
// function of (spec, elapsed seconds), so the whole state machine is
// unit-testable without waiting: the ENGINE derives elapsed from Date
// deltas (accumulated + now-resumedAt), never from accumulated ticks, so
// there is no drift for the math here to inherit.
enum FloteTimer {

    enum Kind: Equatable {
        case stopwatch
        /// Total duration in seconds.
        case countdown(total: Double)
        /// Work/break lengths in seconds; cycles repeat endlessly.
        case pomodoro(work: Double, rest: Double)
    }

    struct Spec: Equatable {
        var kind: Kind
        var title: String?
    }

    enum Phase: Equatable { case work, rest }

    /// Everything the bar needs to draw one frame.
    struct Display: Equatable {
        /// Monospaced digits: "04:32", or "1:04:32" over an hour.
        var text: String
        /// 0…1 within the current phase; nil for stopwatch (no bar).
        var progress: Double?
        /// Pomodoro only.
        var phase: Phase?
        /// Pomodoro only, 1-based.
        var cycle: Int?
        /// Countdown reached its end.
        var finished: Bool
    }

    // MARK: Parsing (fail closed)

    /// Parses a note's first line. Returns nil unless the line is EXACTLY
    /// the token plus an argument shape we know — prose that merely begins
    /// with the letters ("timers are fun", "timer soon") must NOT turn the
    /// note into a timer, so unknown shapes fail closed to a normal note.
    static func parse(firstLine raw: String) -> Spec? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if line.prefix(5).lowercased() == "timer" {
            rest = line.dropFirst(5)
            // The token must stand alone: "timers…" / "timer5" fail closed.
            if let c = rest.first, !c.isWhitespace { return nil }
        } else if line.hasPrefix("タイマー") {
            rest = line.dropFirst(4)
            // JP habitually omits the space before digits (タイマー5); any
            // other glued character (タイマー式…) fails closed.
            if let c = rest.first, !c.isWhitespace, !c.isNumber { return nil }
        } else {
            return nil
        }
        let args = rest.trimmingCharacters(in: .whitespaces)
        if args.isEmpty { return Spec(kind: .stopwatch, title: nil) }

        // First colon (half- or full-width) splits duration from title.
        var numericPart = args
        var title: String?
        if let colon = args.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            numericPart = String(args[args.startIndex..<colon])
            let t = String(args[args.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            title = t.isEmpty ? nil : t
        }
        let tokens = numericPart.split(whereSeparator: { $0.isWhitespace })
        switch tokens.count {
        case 1:
            guard let minutes = strictMinutes(tokens[0]) else { return nil }
            return Spec(kind: .countdown(total: minutes * 60), title: title)
        case 2:
            guard let work = strictMinutes(tokens[0]),
                  let rest = strictMinutes(tokens[1]) else { return nil }
            return Spec(kind: .pomodoro(work: work * 60, rest: rest * 60),
                        title: title)
        default:
            // 0 (colon with no duration) or 3+ numbers: not a shape we know.
            return nil
        }
    }

    /// Strict positive decimal: ASCII digits with at most one interior dot
    /// ("5", "3.5"). Rejects "", "5.", ".5", "-5", "1e3", full-width digits,
    /// zero — anything else means the line was prose, not a duration.
    static func strictMinutes(_ s: Substring) -> Double? {
        var seenDot = false, digitsBefore = 0, digitsAfter = 0
        for ch in s {
            if ch == "." {
                if seenDot { return nil }
                seenDot = true
            } else if ch.isASCII, ch.isNumber {
                if seenDot { digitsAfter += 1 } else { digitsBefore += 1 }
            } else {
                return nil
            }
        }
        guard digitsBefore > 0, !seenDot || digitsAfter > 0,
              let value = Double(s), value > 0, value.isFinite else { return nil }
        return value
    }

    // MARK: Display math

    /// The one source of truth for what the bar shows at `elapsed` seconds.
    /// Countdown finishes at the EXACT boundary (elapsed >= total).
    /// Remaining time is ceiled so a 5-minute timer reads 05:00 at start and
    /// 00:01 until the very end; the stopwatch floors (00:00 for the first
    /// second), matching every system clock's behavior.
    static func display(spec: Spec, elapsed rawElapsed: Double) -> Display {
        let elapsed = max(0, rawElapsed)
        switch spec.kind {
        case .stopwatch:
            return Display(text: format(elapsed.rounded(.down)), progress: nil,
                           phase: nil, cycle: nil, finished: false)
        case .countdown(let total):
            let finished = elapsed >= total
            let remaining = max(0, total - elapsed)
            return Display(text: format(finished ? 0 : remaining.rounded(.up)),
                           progress: total > 0 ? min(1, elapsed / total) : 1,
                           phase: nil, cycle: nil, finished: finished)
        case .pomodoro(let work, let rest):
            let cycleLen = work + rest
            let cycleIndex = (elapsed / cycleLen).rounded(.down)
            let pos = elapsed - cycleIndex * cycleLen
            let inWork = pos < work
            let phaseLen = inWork ? work : rest
            let phaseElapsed = inWork ? pos : pos - work
            let remaining = max(0, phaseLen - phaseElapsed)
            return Display(text: format(remaining.rounded(.up)),
                           progress: phaseLen > 0 ? min(1, phaseElapsed / phaseLen) : 1,
                           phase: inWork ? .work : .rest,
                           cycle: Int(cycleIndex) + 1,
                           finished: false)
        }
    }

    /// Pause math: total elapsed = banked seconds + the live run segment.
    /// While paused (`resumedAt == nil`) time simply does not pass.
    static func totalElapsed(accumulated: Double, resumedAt: Date?, now: Date) -> Double {
        guard let resumedAt else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(resumedAt))
    }

    /// The elapsed-seconds mark of the next audible event: countdown finish,
    /// or the next pomodoro phase boundary (work→break or break→work).
    /// nil = nothing will ever fire (stopwatch, or countdown already done).
    static func nextEvent(spec: Spec, elapsed: Double) -> Double? {
        switch spec.kind {
        case .stopwatch:
            return nil
        case .countdown(let total):
            return elapsed < total ? total : nil
        case .pomodoro(let work, let rest):
            let cycleLen = work + rest
            let cycleIndex = (max(0, elapsed) / cycleLen).rounded(.down)
            let pos = max(0, elapsed) - cycleIndex * cycleLen
            return pos < work
                ? cycleIndex * cycleLen + work
                : (cycleIndex + 1) * cycleLen
        }
    }

    /// "mm:ss", or "h:mm:ss" past an hour.
    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}
// S10-TIMER-PURE-END

// MARK: - Engine (session state, event scheduling, finish cues)

/// In-memory timer sessions keyed by note id. NOT persisted by design:
/// relaunching the app clears every timer (documented v1 behavior). The
/// engine owns WHEN things happen; all math lives in FloteTimer above.
@MainActor
@Observable
final class TimerEngine {

    static let shared = TimerEngine()
    private init() {}

    struct Session {
        var spec: FloteTimer.Spec
        /// Seconds banked across previous run segments.
        var accumulated: Double = 0
        /// Wall-clock start of the current run segment; nil while paused.
        var resumedAt: Date?
        /// Countdown finish cue fired (never fire twice for one run).
        var finishedFired = false

        var isRunning: Bool { resumedAt != nil }

        func elapsed(now: Date = Date()) -> Double {
            FloteTimer.totalElapsed(
                accumulated: accumulated, resumedAt: resumedAt, now: now)
        }
    }

    private(set) var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var eventTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var didRequestNotificationAuth = false

    func session(for noteID: UUID) -> Session? { sessions[noteID] }

    /// Reconcile with the note's current first line. A spec CHANGE (user
    /// edited "timer 5" → "timer 10") hard-resets to idle — the old run is
    /// meaningless against the new duration. Same spec = no-op, so panel
    /// close/reopen re-attaches to the running session.
    func sync(noteID: UUID, spec: FloteTimer.Spec) {
        if let existing = sessions[noteID] {
            guard existing.spec != spec else { return }
            cancelEventTask(noteID)
            sessions[noteID] = Session(spec: spec)
        } else {
            sessions[noteID] = Session(spec: spec)
        }
    }

    /// Play/pause. Starting a finished countdown restarts it from zero.
    func togglePause(noteID: UUID) {
        guard var s = sessions[noteID] else { return }
        if let resumedAt = s.resumedAt {
            s.accumulated += max(0, Date().timeIntervalSince(resumedAt))
            s.resumedAt = nil
            sessions[noteID] = s
            cancelEventTask(noteID)
        } else {
            if case .countdown(let total) = s.spec.kind, s.accumulated >= total {
                s = Session(spec: s.spec) // restart a finished countdown
            }
            s.resumedAt = Date()
            sessions[noteID] = s
            requestNotificationAuthIfNeeded(kind: s.spec.kind)
            scheduleEventTask(noteID)
        }
    }

    /// Stop = reset to idle (full duration shown, nothing banked).
    func stop(noteID: UUID) {
        guard let s = sessions[noteID] else { return }
        cancelEventTask(noteID)
        sessions[noteID] = Session(spec: s.spec)
    }

    /// The note stopped being a timer note (first line edited away) or was
    /// deleted — forget everything, cancel any pending cue.
    func drop(noteID: UUID) {
        cancelEventTask(noteID)
        sessions[noteID] = nil
    }

    // MARK: Event scheduling

    /// One structured task per running session sleeps until the next
    /// boundary computed from Date deltas, then re-checks against the wall
    /// clock before firing — an early or late wake (system sleep, timer
    /// coalescing) can never drift the fire point, only delay its delivery.
    private func scheduleEventTask(_ noteID: UUID) {
        cancelEventTask(noteID)
        guard let s = sessions[noteID], s.isRunning,
              FloteTimer.nextEvent(spec: s.spec, elapsed: s.elapsed()) != nil
        else { return }
        eventTasks[noteID] = Task { [weak self] in
            await self?.runEventLoop(noteID: noteID)
        }
    }

    private func cancelEventTask(_ noteID: UUID) {
        eventTasks[noteID]?.cancel()
        eventTasks[noteID] = nil
    }

    private func runEventLoop(noteID: UUID) async {
        while !Task.isCancelled {
            guard let s = sessions[noteID], s.isRunning,
                  let mark = FloteTimer.nextEvent(spec: s.spec, elapsed: s.elapsed())
            else { return }
            let wait = mark - s.elapsed()
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                continue // re-check the wall clock; loop fires only when past the mark
            }
            fireEvent(noteID: noteID, atMark: mark)
            // Countdown: nextEvent is now nil → loop exits. Pomodoro: loop
            // continues to the next phase boundary.
        }
    }

    private func fireEvent(noteID: UUID, atMark mark: Double) {
        guard var s = sessions[noteID] else { return }
        // Note deleted while the timer ran with its panel closed: no cue for
        // a ghost — drop the whole session.
        guard NoteManager.shared.note(byID: noteID) != nil else {
            drop(noteID: noteID)
            return
        }
        switch s.spec.kind {
        case .stopwatch:
            return
        case .countdown:
            guard !s.finishedFired else { return }
            s.finishedFired = true
            // Freeze exactly at the boundary so the bar reads 00:00 /
            // finished no matter when the next frame renders.
            s.accumulated = mark
            s.resumedAt = nil
            sessions[noteID] = s
            fireCue(noteID: noteID, spec: s.spec,
                    body: L("タイマーが終了しました", "Timer finished"))
        case .pomodoro:
            // display() at the mark already reports the NEW phase.
            let display = FloteTimer.display(spec: s.spec, elapsed: mark)
            let body = display.phase == .rest
                ? L("休憩の時間です", "Time for a break")
                : L("作業に戻る時間です", "Back to work")
            fireCue(noteID: noteID, spec: s.spec, body: body)
        }
    }

    /// The three finish cues: system sound + transient border pulse (only a
    /// live panel shows it) + user notification (fires even with the panel
    /// closed — the whole point of keeping the engine outside the view).
    private func fireCue(noteID: UUID, spec: FloteTimer.Spec, body: String) {
        if let sound = NSSound(named: "Glass") {
            sound.play()
        } else {
            NSSound.beep()
        }
        NotificationCenter.default.post(
            name: .floteTimerPulse, object: nil, userInfo: ["noteID": noteID])
        let content = UNMutableNotificationContent()
        content.title = spec.title ?? L("Flote タイマー", "Flote Timer")
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "flote-timer-\(noteID.uuidString)-\(UUID().uuidString)",
            content: content, trigger: nil) // nil trigger = deliver now
        UNUserNotificationCenter.current().add(request)
    }

    /// Request-on-first-use discipline (same policy as ReminderService):
    /// the permission dialog appears the first time the user STARTS a timer
    /// that will ring — never at launch, never for a stopwatch (it has no
    /// finish). Denied = the notification quietly stays away; the in-note
    /// sound + pulse still fire, so the timer remains fully usable.
    private func requestNotificationAuthIfNeeded(kind: FloteTimer.Kind) {
        if case .stopwatch = kind { return }
        guard !didRequestNotificationAuth else { return }
        didRequestNotificationAuth = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension Notification.Name {
    /// Finish cue → the note's open panel pulses its border once via a
    /// transient OVERLAY view (never the panel frame — crash invariant).
    static let floteTimerPulse = Notification.Name("floteTimerPulse")
}

// MARK: - TimerRail (left-margin rail beside the editor)

/// Antinote's real timer UI (LP screenshot analysis, spec Appendix C) is a
/// LEFT-MARGIN RAIL, not a bar: a narrow vertical column running the note's
/// full height, dots filling with theme accent as time progresses, tiny
/// monospaced digits top (set duration) and bottom (live readout, stacked
/// mm over ss). The note text lives to its right, fully editable.
///
/// Top→bottom: set duration · title (stacked chars, tooltip carries the
/// full text) · dots · phase chip + cycle (pomodoro) · readout · ▶/⏸ · ◼.
/// Ticking happens HERE only — a TimelineView while running, at 0.5 s so a
/// ceiled countdown never visibly skips a second; the engine itself never
/// ticks, it only sleeps until boundaries. Reduce Motion: the dots column
/// is dropped entirely (text readout only, discrete updates). Stopwatch has
/// no bounded progress, so its dots sweep once per minute (the milestone
/// feel Antinote gives stopwatch mode).
struct TimerRail: View {
    let noteID: UUID
    let spec: FloteTimer.Spec
    let ink: Color
    let accent: Color

    static let railWidth: CGFloat = 18

    var body: some View {
        Group {
            if TimerEngine.shared.session(for: noteID)?.isRunning ?? false {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    rail(now: context.date)
                }
            } else {
                rail(now: Date())
            }
        }
        .onAppear { TimerEngine.shared.sync(noteID: noteID, spec: spec) }
        .onChange(of: spec) { _, newSpec in
            TimerEngine.shared.sync(noteID: noteID, spec: newSpec)
        }
    }

    private func rail(now: Date) -> some View {
        let session = TimerEngine.shared.session(for: noteID)
            ?? TimerEngine.Session(spec: spec)
        let elapsed = session.elapsed(now: now)
        let display = FloteTimer.display(spec: session.spec, elapsed: elapsed)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let idle = !session.isRunning && session.accumulated == 0

        return VStack(spacing: 4) {
            // Set duration, e.g. "5m" / "25/5"; stopwatch gets its glyph.
            Group {
                if case .stopwatch = session.spec.kind {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 8, weight: .semibold))
                } else {
                    Text(Self.durationLabel(session.spec.kind))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundColor(ink.opacity(0.55))

            if let title = session.spec.title {
                // Tategaki-style stacked characters — natural for JP titles,
                // acceptable for short EN; the tooltip carries the full text.
                Text(title.prefix(6).map(String.init).joined(separator: "\n"))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundColor(ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .help(title)
            }

            if reduceMotion {
                Spacer(minLength: 2)
            } else {
                dots(progress: Self.dotsProgress(display: display, elapsed: elapsed))
                    .frame(maxHeight: .infinity)
            }

            if let phase = display.phase {
                Text(phase == .work ? L("作", "W") : L("休", "B"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(phase == .work ? accent : ink.opacity(0.6))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle().fill((phase == .work ? accent : ink).opacity(0.12)))
                    .help(phase == .work ? L("作業", "Work") : L("休憩", "Break"))
                if let cycle = display.cycle {
                    Text("×\(cycle)")
                        .font(.system(size: 8, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(ink.opacity(0.5))
                        .help(L("\(cycle)周目", "Cycle \(cycle)"))
                }
            }

            readout(display.text, finished: display.finished)

            Button(action: { TimerEngine.shared.togglePause(noteID: noteID) }) {
                Image(systemName: session.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: Self.railWidth, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.isRunning ? L("一時停止", "Pause") : L("スタート", "Start"))
            .accessibilityLabel(session.isRunning
                ? L("タイマーを一時停止", "Pause timer")
                : L("タイマーをスタート", "Start timer"))

            Button(action: { TimerEngine.shared.stop(noteID: noteID) }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(ink.opacity(idle ? 0.2 : 0.45))
                    .frame(width: Self.railWidth, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(idle)
            .help(L("停止（リセット）", "Stop (reset)"))
            .accessibilityLabel(L("タイマーを停止", "Stop timer"))
        }
        .frame(width: Self.railWidth)
        .padding(.vertical, 2)
    }

    /// Live readout, stacked mm over ss (h/mm/ss past an hour) — the only
    /// way real digits fit an 18 pt rail, and exactly Antinote's bottom-left
    /// stacked look. Monospaced SF Rounded.
    private func readout(_ text: String, finished: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(text.split(separator: ":").enumerated()), id: \.offset) { _, part in
                Text(String(part))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundColor(finished ? accent : ink.opacity(0.85))
        .accessibilityLabel(L("残り時間", "Time") + " " + text)
    }

    /// The dots column: as many 4 pt dots as the available height affords,
    /// filled top-down with the theme accent as time progresses. No
    /// .animation anywhere — fills update discretely per tick.
    private func dots(progress: Double) -> some View {
        GeometryReader { geo in
            let count = max(3, Int(geo.size.height / 10))
            let filled = Int((progress * Double(count)).rounded(.down))
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? accent.opacity(0.85) : ink.opacity(0.15))
                        .frame(width: 4, height: 4)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width)
        }
    }

    /// Countdown/pomodoro use the phase progress; the unbounded stopwatch
    /// sweeps the column once per minute.
    private static func dotsProgress(display: FloteTimer.Display, elapsed: Double) -> Double {
        if let p = display.progress { return p }
        return max(0, elapsed).truncatingRemainder(dividingBy: 60) / 60
    }

    /// "5m" / "3.5m" / "25/5" — the SET duration shown at the rail's top.
    private static func durationLabel(_ kind: FloteTimer.Kind) -> String {
        func minutes(_ seconds: Double) -> String {
            let m = seconds / 60
            return m == m.rounded(.down) ? String(Int(m)) : String(m)
        }
        switch kind {
        case .stopwatch:
            return ""
        case .countdown(let total):
            return minutes(total) + "m"
        case .pomodoro(let work, let rest):
            return minutes(work) + "/" + minutes(rest)
        }
    }
}

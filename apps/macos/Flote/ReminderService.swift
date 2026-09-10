import Foundation
@preconcurrency import UserNotifications

/// S6: reminders on checkbox items — the category leapfrog (only NotePlan
/// has it). Right-click a checkbox line → pick a time → a local
/// notification fires with the item text. Checking the item off cancels
/// its pending reminder.
///
/// Zero-interruption policy (S5): notification permission is requested on
/// FIRST USE — the moment the user picks a reminder time — never at launch.
/// A denied permission surfaces as a transient note error, and scheduling
/// FAILS CLOSED (no silent "reminder set" that can never fire).
///
/// Identity: a reminder is keyed by (noteID, item text). Same-text
/// duplicates within one note collapse to one reminder (re-scheduling
/// replaces). The text key means editing the item's wording orphans the
/// old reminder — accepted for v1 (it still fires, its text names the
/// original item; Recently-Deleted-grade bookkeeping is post-v1).
@MainActor
enum ReminderService {

    /// Quick-pick offsets shown in the context menu.
    enum Preset: CaseIterable {
        case inOneHour
        case inThreeHours
        case thisEvening
        case tomorrowMorning

        @MainActor
        var title: String {
            switch self {
            case .inOneHour:       return L("1時間後", "In 1 hour")
            case .inThreeHours:    return L("3時間後", "In 3 hours")
            case .thisEvening:     return L("今日の夜（20時）", "This evening (8 PM)")
            case .tomorrowMorning: return L("明日の朝（9時）", "Tomorrow morning (9 AM)")
            }
        }

        /// Next fire date. Presets that already passed today roll to the
        /// sensible next slot (20時 past → tomorrow 20時).
        var fireDate: Date {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .inOneHour:
                return now.addingTimeInterval(3600)
            case .inThreeHours:
                return now.addingTimeInterval(3 * 3600)
            case .thisEvening:
                let today8pm = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)!
                return today8pm > now ? today8pm : cal.date(byAdding: .day, value: 1, to: today8pm)!
            case .tomorrowMorning:
                let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
                return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
            }
        }
    }

    /// Stable identifier for one checkbox item's reminder. SHA-free: the
    /// text goes through a Unicode-safe base64 so 日本語 items key cleanly.
    nonisolated static func identifier(noteID: UUID, itemText: String) -> String {
        let keyText = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = Data(keyText.utf8).base64EncodedString()
        return "flote-reminder-\(noteID.uuidString)-\(encoded)"
    }

    /// Request-on-first-use permission, then schedule. `onResult` is called
    /// on the main actor with a user-facing JP error, or nil on success.
    static func schedule(
        noteID: UUID,
        noteTitle: String?,
        itemText: String,
        at date: Date,
        onResult: @escaping @MainActor (String?) -> Void
    ) {
        let trimmed = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onResult(L("この行にはリマインドする内容がありません", "This line has nothing to remind about"))
            return
        }
        guard date > Date() else {
            onResult(L("過去の時刻にはリマインドできません", "Cannot set a reminder in the past"))
            return
        }
        let requestID = identifier(noteID: noteID, itemText: trimmed)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in
                    onResult(L("通知が許可されていません（システム設定 > 通知 > Flote）", "Notifications are not allowed (System Settings > Notifications > Flote)"))
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = noteTitle ?? "Flote"
            content.body = trimmed
            content.sound = .default
            let interval = max(1, date.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: requestID, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                Task { @MainActor in
                    onResult(error.map { L("リマインダーを設定できませんでした", "Could not set the reminder") + "（\($0.localizedDescription)）" })
                }
            }
        }
    }

    /// Cancel the pending reminder for one item (fired when the user checks
    /// it off — a completed task should not ring).
    static func cancel(noteID: UUID, itemText: String) {
        let id = identifier(noteID: noteID, itemText: itemText)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Cancel every pending reminder belonging to a note (delete path).
    static func cancelAll(noteID: UUID) {
        let prefix = "flote-reminder-\(noteID.uuidString)-"
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

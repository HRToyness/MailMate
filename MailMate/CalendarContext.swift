import EventKit
import Foundation

/// Reads the next few days of calendar events from EventKit and renders them
/// into a compact "busy window" summary for injection into the LLM prompt.
/// Gated behind `include_calendar` UserDefaults key.
enum CalendarContext {
    /// Returns a plain-text summary of busy windows for the next `days` days,
    /// or nil if the toggle is off or access is denied. Prompts for calendar
    /// permission the first time if needed.
    @MainActor
    static func summaryIfEnabled(days: Int = 7) async -> String? {
        guard UserDefaults.standard.bool(forKey: "include_calendar") else { return nil }
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14, *) {
            do { granted = try await store.requestFullAccessToEvents() }
            catch {
                Log.write("Calendar permission error: \(error.localizedDescription)")
                granted = false
            }
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else {
            Log.write("Calendar permission denied")
            return nil
        }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end,
                                                 calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            return "My calendar for the next \(days) days is currently open."
        }

        let df = DateFormatter()
        df.dateFormat = "EEE d MMM HH:mm"
        let windows = events.prefix(40).map { ev -> String in
            let start = df.string(from: ev.startDate)
            let endTime = DateFormatter()
            endTime.dateFormat = "HH:mm"
            let endStr = endTime.string(from: ev.endDate)
            let title = ev.title ?? "busy"
            return "- \(start)–\(endStr): \(title)"
        }.joined(separator: "\n")

        return """
        My calendar (busy windows, next \(days) days, local time):
        \(windows)
        """
    }
}

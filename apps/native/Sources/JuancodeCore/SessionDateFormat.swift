import Foundation

/// Compact session-date labels for the sidebar subtitle: time of day for
/// today's sessions ("14:03"), day+month within the current year ("26 Jul"),
/// and day+month+year beyond that ("26 Jul 25").
public enum SessionDateFormat {
    public static func compact(msSinceEpoch: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(msSinceEpoch) / 1000)
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            fmt.dateFormat = "HH:mm"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            fmt.dateFormat = "d MMM"
        } else {
            fmt.dateFormat = "d MMM yy"
        }
        return fmt.string(from: date)
    }
}

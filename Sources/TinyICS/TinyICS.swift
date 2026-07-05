import Foundation

/// A parsed VEVENT.
public struct ICSEvent: Equatable {
    public var uid = ""
    public var summary = ""
    public var start: Date?
    public var end: Date?
    public var isAllDay = false
    public var rrule: [String: String]?
    public var exdateKeys: Set<String> = []
    /// Set when this VEVENT overrides one instance of a recurring series (RECURRENCE-ID).
    public var recurrenceDateKey: String?

    public init() {}
}

/// One concrete occurrence of an event on a given day.
public struct ICSOccurrence: Equatable {
    public let event: ICSEvent
    public let start: Date
    public let end: Date
}

/// A tiny, zero-dependency ICS (RFC 5545) parser for Swift.
///
/// Scope, honestly stated:
/// - Parses VEVENTs: UID, SUMMARY, DTSTART/DTEND (TZID, UTC "Z", all-day DATE), RRULE, EXDATE, RECURRENCE-ID.
/// - Expands recurrence for FREQ=DAILY and FREQ=WEEKLY (INTERVAL, BYDAY, UNTIL, COUNT for daily),
///   honoring EXDATE exclusions and RECURRENCE-ID instance overrides.
/// - Does NOT handle MONTHLY/YEARLY rules, VTODO/VJOURNAL, or the long tail of RFC 5545.
///
/// Built for the common case: "give me today's events from a Google Calendar secret ICS feed."
public enum TinyICS {

    // MARK: - Parsing

    public static func parse(_ text: String) -> [ICSEvent] {
        // CRITICAL, and the reason this library exists as a cautionary tale:
        // in Swift, "\r\n" is ONE Character (an extended grapheme cluster).
        // Splitting a CRLF file on "\n" therefore never splits — the whole
        // feed arrives as a single "line" and zero events parse. Normalize first.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Unfold: RFC 5545 continuation lines begin with a space or tab.
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }

        var events: [ICSEvent] = []
        var current: ICSEvent?

        for line in lines {
            if line == "BEGIN:VEVENT" { current = ICSEvent(); continue }
            if line == "END:VEVENT" {
                if let e = current { events.append(e) }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }

            let head = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            let headParts = head.split(separator: ";").map(String.init)
            let name = headParts.first?.uppercased() ?? ""
            var params: [String: String] = [:]
            for p in headParts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
            }

            switch name {
            case "UID":
                current?.uid = value
            case "SUMMARY":
                current?.summary = value
                    .replacingOccurrences(of: "\\,", with: ",")
                    .replacingOccurrences(of: "\\;", with: ";")
            case "DTSTART":
                let parsed = parseDate(value, params: params)
                current?.start = parsed.date
                current?.isAllDay = parsed.isAllDay
            case "DTEND":
                current?.end = parseDate(value, params: params).date
            case "RRULE":
                var rule: [String: String] = [:]
                for kv in value.split(separator: ";") {
                    let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 { rule[pair[0].uppercased()] = pair[1] }
                }
                current?.rrule = rule
            case "EXDATE":
                for v in value.split(separator: ",") {
                    if let d = parseDate(String(v), params: params).date {
                        current?.exdateKeys.insert(dayKey(d))
                    }
                }
            case "RECURRENCE-ID":
                if let d = parseDate(value, params: params).date {
                    current?.recurrenceDateKey = dayKey(d)
                }
            default:
                break
            }
        }
        return events
    }

    // MARK: - Occurrence expansion

    /// All occurrences of the given events on the calendar day containing `day`.
    public static func occurrences(
        in events: [ICSEvent],
        on day: Date = .now,
        calendar: Calendar = .current
    ) -> [ICSOccurrence] {
        let dayStart = calendar.startOfDay(for: day)
        let targetKey = dayKey(day)

        // uid → override day-keys, so masters skip overridden instances.
        var overrideKeys: [String: Set<String>] = [:]
        for e in events {
            if let rk = e.recurrenceDateKey {
                overrideKeys[e.uid, default: []].insert(rk)
            }
        }

        var out: [ICSOccurrence] = []

        for e in events {
            guard let start = e.start else { continue }
            let duration = e.end.map { $0.timeIntervalSince(start) } ?? 3600

            // Override instance: include if its (possibly moved) start is on the day.
            if e.recurrenceDateKey != nil {
                if dayKey(start) == targetKey {
                    out.append(ICSOccurrence(event: e, start: start, end: start.addingTimeInterval(duration)))
                }
                continue
            }

            guard let rule = e.rrule else {
                if dayKey(start) == targetKey {
                    out.append(ICSOccurrence(event: e, start: start, end: start.addingTimeInterval(duration)))
                }
                continue
            }

            // Recurring master
            if e.exdateKeys.contains(targetKey) { continue }
            if overrideKeys[e.uid]?.contains(targetKey) == true { continue }
            guard ruleOccurs(rule, dtstart: start, onDayStarting: dayStart, calendar: calendar) else { continue }

            // The day's instance keeps the original time of day.
            let t = calendar.dateComponents([.hour, .minute, .second], from: start)
            let instStart = calendar.date(
                bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0,
                of: dayStart
            ) ?? dayStart
            out.append(ICSOccurrence(event: e, start: instStart, end: instStart.addingTimeInterval(duration)))
        }

        return out.sorted { $0.start < $1.start }
    }

    // MARK: - Internals

    static func parseDate(_ value: String, params: [String: String]) -> (date: Date?, isAllDay: Bool) {
        // All-day: VALUE=DATE or bare yyyyMMdd
        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let f = posixFormatter("yyyyMMdd", timeZone: .current)
            return (f.date(from: value), true)
        }
        // UTC: ...Z
        if value.hasSuffix("Z") {
            let f = posixFormatter("yyyyMMdd'T'HHmmss'Z'", timeZone: TimeZone(identifier: "UTC")!)
            return (f.date(from: value), false)
        }
        // TZID-qualified or floating (interpreted in the current zone)
        let tz: TimeZone
        if let tzid = params["TZID"], let t = TimeZone(identifier: tzid) {
            tz = t
        } else {
            tz = .current
        }
        let f = posixFormatter("yyyyMMdd'T'HHmmss", timeZone: tz)
        return (f.date(from: value), false)
    }

    /// en_US_POSIX is not optional. Without it, fixed-format parsing is hostage
    /// to the device's 12/24-hour setting and can silently return nil (Apple QA1480).
    private static func posixFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.timeZone = timeZone
        return f
    }

    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = calendar.timeZone
        return f.string(from: d)
    }

    private static func ruleOccurs(
        _ rule: [String: String],
        dtstart: Date,
        onDayStarting dayStart: Date,
        calendar cal: Calendar
    ) -> Bool {
        let startDay = cal.startOfDay(for: dtstart)
        guard dayStart >= startDay else { return false }

        if let untilStr = rule["UNTIL"],
           let until = parseDate(untilStr, params: [:]).date,
           dayStart > until {
            return false
        }

        let interval = Int(rule["INTERVAL"] ?? "1") ?? 1
        let daysBetween = cal.dateComponents([.day], from: startDay, to: dayStart).day ?? 0

        switch rule["FREQ"] {
        case "DAILY":
            guard daysBetween % interval == 0 else { return false }
            if let countStr = rule["COUNT"], let count = Int(countStr) {
                return (daysBetween / interval) < count
            }
            return true

        case "WEEKLY":
            let targetWeekday = cal.component(.weekday, from: dayStart)
            if let byday = rule["BYDAY"] {
                let codes = Set(byday.split(separator: ",").map(String.init))
                guard codes.contains(weekdayCode(targetWeekday)) else { return false }
            } else {
                guard targetWeekday == cal.component(.weekday, from: dtstart) else { return false }
            }
            guard
                let w1 = cal.dateInterval(of: .weekOfYear, for: startDay)?.start,
                let w2 = cal.dateInterval(of: .weekOfYear, for: dayStart)?.start,
                let weekDays = cal.dateComponents([.day], from: w1, to: w2).day
            else { return false }
            let weeks = weekDays / 7
            guard weeks % interval == 0 else { return false }
            // COUNT on WEEKLY is unsupported (rare on standing events); documented limitation.
            return true

        default:
            return false
        }
    }

    private static func weekdayCode(_ weekday: Int) -> String {
        // Calendar weekday: 1 = Sunday … 7 = Saturday
        ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"][weekday]
    }
}

import XCTest
@testable import TinyICS

final class TinyICSTests: XCTestCase {

    // MARK: - Helpers

    /// A realistic Google-Calendar-shaped feed. CRLF line endings on purpose —
    /// that's what Google actually serves, and it's what bit us. See test below.
    private func googleStyleFeed(lineEnding: String = "\r\n") -> String {
        [
            "BEGIN:VCALENDAR",
            "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "X-WR-TIMEZONE:America/New_York",
            "BEGIN:VEVENT",
            "DTSTART;TZID=America/New_York:20260705T130000",
            "DTEND;TZID=America/New_York:20260705T170000",
            "RRULE:FREQ=WEEKLY;BYDAY=SU",
            "UID:weekly-sunday@example.com",
            "DESCRIPTION:A long description that google folds onto the next line beca",
            " use it exceeds 75 octets per RFC 5545 folding rules",
            "SUMMARY:Weekly Sunday thing",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "DTSTART;TZID=America/New_York:20260703T190000",
            "DTEND;TZID=America/New_York:20260703T200000",
            "UID:one-off@example.com",
            "SUMMARY:One-off Friday thing\\, with an escaped comma",
            "END:VEVENT",
            "END:VCALENDAR",
            ""
        ].joined(separator: lineEnding)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return Calendar.current.date(from: comps)!
    }

    // MARK: - The regression that motivated this library

    /// In Swift, "\r\n" is a single Character (extended grapheme cluster), so
    /// `split(separator: "\n")` on a CRLF feed NEVER splits. A parser that
    /// forgets to normalize sees the entire feed as one line and returns zero
    /// events — with no error, on a perfectly valid 200 response. This test
    /// exists so that bug can never come back.
    func testCRLFFeedParses() {
        let events = TinyICS.parse(googleStyleFeed(lineEnding: "\r\n"))
        XCTAssertEqual(events.count, 2)
    }

    func testLFFeedParsesIdentically() {
        let crlf = TinyICS.parse(googleStyleFeed(lineEnding: "\r\n"))
        let lf = TinyICS.parse(googleStyleFeed(lineEnding: "\n"))
        XCTAssertEqual(crlf.count, lf.count)
        XCTAssertEqual(crlf.map(\.uid), lf.map(\.uid))
    }

    // MARK: - Parsing details

    func testFoldedLinesUnfoldAndSummaryUnescapes() {
        let events = TinyICS.parse(googleStyleFeed())
        XCTAssertEqual(events[1].summary, "One-off Friday thing, with an escaped comma")
    }

    func testTZIDDateParses() {
        let events = TinyICS.parse(googleStyleFeed())
        XCTAssertNotNil(events[0].start)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: events[0].start!)
        XCTAssertEqual(comps.hour, 13)
        XCTAssertEqual(comps.day, 5)
    }

    func testZuluDateParses() {
        let feed = """
        BEGIN:VEVENT\r
        DTSTART:20260705T110000Z\r
        UID:z@example.com\r
        SUMMARY:Zulu\r
        END:VEVENT\r
        """
        let events = TinyICS.parse(feed)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events[0].start)
    }

    func testAllDayEvent() {
        let feed = """
        BEGIN:VEVENT\r
        DTSTART;VALUE=DATE:20260705\r
        DTEND;VALUE=DATE:20260706\r
        UID:allday@example.com\r
        SUMMARY:All day\r
        END:VEVENT\r
        """
        let events = TinyICS.parse(feed)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isAllDay)
    }

    // MARK: - Occurrence expansion

    func testWeeklyRecurrenceOccursOnMatchingWeekday() {
        let events = TinyICS.parse(googleStyleFeed())
        // 2026-07-12 is the Sunday after DTSTART (2026-07-05, also a Sunday).
        let occ = TinyICS.occurrences(in: events, on: date(2026, 7, 12))
        XCTAssertTrue(occ.contains { $0.event.uid == "weekly-sunday@example.com" })
        // A Tuesday should not match.
        let tue = TinyICS.occurrences(in: events, on: date(2026, 7, 14))
        XCTAssertFalse(tue.contains { $0.event.uid == "weekly-sunday@example.com" })
    }

    func testNonRecurringOccursOnlyOnItsDay() {
        let events = TinyICS.parse(googleStyleFeed())
        let onDay = TinyICS.occurrences(in: events, on: date(2026, 7, 3))
        XCTAssertTrue(onDay.contains { $0.event.uid == "one-off@example.com" })
        let offDay = TinyICS.occurrences(in: events, on: date(2026, 7, 10))
        XCTAssertFalse(offDay.contains { $0.event.uid == "one-off@example.com" })
    }

    func testEXDATEExcludesInstance() {
        let feed = """
        BEGIN:VEVENT\r
        DTSTART;TZID=America/New_York:20260705T130000\r
        DTEND;TZID=America/New_York:20260705T140000\r
        RRULE:FREQ=WEEKLY;BYDAY=SU\r
        EXDATE;TZID=America/New_York:20260712T130000\r
        UID:ex@example.com\r
        SUMMARY:Weekly with a skip\r
        END:VEVENT\r
        """
        let events = TinyICS.parse(feed)
        let skipped = TinyICS.occurrences(in: events, on: date(2026, 7, 12))
        XCTAssertFalse(skipped.contains { $0.event.uid == "ex@example.com" })
        let normal = TinyICS.occurrences(in: events, on: date(2026, 7, 19))
        XCTAssertTrue(normal.contains { $0.event.uid == "ex@example.com" })
    }

    func testRecurrenceOverrideReplacesMasterInstance() {
        let feed = """
        BEGIN:VEVENT\r
        DTSTART;TZID=America/New_York:20260705T130000\r
        DTEND;TZID=America/New_York:20260705T140000\r
        RRULE:FREQ=WEEKLY;BYDAY=SU\r
        UID:series@example.com\r
        SUMMARY:Series\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        DTSTART;TZID=America/New_York:20260712T160000\r
        DTEND;TZID=America/New_York:20260712T170000\r
        RECURRENCE-ID;TZID=America/New_York:20260712T130000\r
        UID:series@example.com\r
        SUMMARY:Series (moved)\r
        END:VEVENT\r
        """
        let events = TinyICS.parse(feed)
        let occ = TinyICS.occurrences(in: events, on: date(2026, 7, 12))
        let matches = occ.filter { $0.event.uid == "series@example.com" }
        XCTAssertEqual(matches.count, 1, "master and override must not both fire")
        XCTAssertEqual(matches.first?.event.summary, "Series (moved)")
    }

    func testDailyIntervalAndCount() {
        let feed = """
        BEGIN:VEVENT\r
        DTSTART;TZID=America/New_York:20260701T080000\r
        DTEND;TZID=America/New_York:20260701T083000\r
        RRULE:FREQ=DAILY;INTERVAL=2;COUNT=3\r
        UID:daily@example.com\r
        SUMMARY:Every other day, three times\r
        END:VEVENT\r
        """
        let events = TinyICS.parse(feed)
        // Occurrences: Jul 1, 3, 5. Jul 2 (off-interval) and Jul 7 (past COUNT) must not fire.
        XCTAssertTrue(TinyICS.occurrences(in: events, on: date(2026, 7, 5)).count == 1)
        XCTAssertTrue(TinyICS.occurrences(in: events, on: date(2026, 7, 2)).isEmpty)
        XCTAssertTrue(TinyICS.occurrences(in: events, on: date(2026, 7, 7)).isEmpty)
    }
}

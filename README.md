# TinyICS

A tiny, zero-dependency ICS (RFC 5545) parser for Swift, built for one common job: **"give me today's events from a calendar feed"** — like a Google Calendar secret ICS URL.

```swift
import TinyICS

let events = TinyICS.parse(feedText)
let today = TinyICS.occurrences(in: events, on: .now)

for occ in today {
    print(occ.event.summary, occ.start, occ.end)
}
```

## What it handles

- VEVENT parsing: `UID`, `SUMMARY` (with escape unfolding), `DTSTART`/`DTEND` — `TZID`-qualified, UTC (`Z`), and all-day (`VALUE=DATE`)
- RFC 5545 line unfolding (folded long lines)
- **CRLF and LF feeds** (see war story below)
- Recurrence expansion for `FREQ=DAILY` and `FREQ=WEEKLY`: `INTERVAL`, `BYDAY`, `UNTIL`, `COUNT` (daily)
- `EXDATE` exclusions
- `RECURRENCE-ID` instance overrides (a single moved/edited occurrence replaces its master instance)

## What it deliberately doesn't

`MONTHLY`/`YEARLY` rules, `COUNT` on weekly rules, `VTODO`/`VJOURNAL`/`VALARM`, and the long tail of RFC 5545. If your use case is a personal dashboard reading a feed of appointments and standing weekly events, you're covered. If you need full RFC compliance, you want a bigger library.

## The war story (or: why this exists)

This parser shipped inside a personal iOS app and returned **zero events** from a perfectly valid 460KB Google Calendar feed — HTTP 200, `text/calendar`, starts with `BEGIN:VCALENDAR`, 645 `VEVENT`s confirmed via `curl | grep`. No error anywhere.

The cause: **in Swift, `"\r\n"` is a single `Character`.** Swift's `Character` is an extended grapheme cluster, and Unicode defines CRLF as one cluster — so

```swift
text.split(separator: "\n")   // on a CRLF file: NEVER SPLITS
```

returns the entire feed as one giant "line". Every `line == "BEGIN:VEVENT"` comparison fails, and the parser politely returns an empty array. It's invisible to byte-oriented tools: `curl`, `grep`, and a line-by-line Python port of the same logic all handle CRLF fine — which is exactly how the bug survived a "the logic is correct, I tested a port of it" false acquittal.

The fix is one line (`replacingOccurrences(of: "\r\n", with: "\n")` before splitting), and the regression test `testCRLFFeedParses` makes sure it never comes back.

Second landmine, also encoded here: every fixed-format `DateFormatter` uses `en_US_POSIX`. Without it, `HHmmss` parsing is hostage to the device's 12/24-hour setting and can silently return `nil` ([Apple QA1480](https://developer.apple.com/library/archive/qa/qa1480/_index.html)).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/YOURUSER/TinyICS.git", from: "0.1.0")
```

## License

MIT

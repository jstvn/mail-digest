import MailDigestCore
import struct Foundation.Date

/// Real-time clock for the app; tests inject fixed clocks instead.
struct SystemClock: Clock {
    func now() -> Date { Date() }
}

import MailDigestCore
import SwiftUI

/// The top of Today: the date overline, a greeting by time of day and the model's brief.
struct TodayHeader: View {
    let now: Date
    /// The Mac's current calendar: the greeting follows the local time of day.
    let greetingCalendar: Calendar
    /// The fixed review calendar for the date overline.
    let dateCalendar: Calendar
    /// The macOS account's full name; the greeting uses its first word.
    let fullName: String
    /// The digest's one-sentence summary. A bare count ("12 emails, 3 suggestions.") is not shown as a brief.
    let headline: String

    private var showsBrief: Bool {
        !headline.isEmpty && !ReviewPresentation.isCountOnlyHeadline(headline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TodayGreeting.dateOverline(now: now, calendar: dateCalendar))
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.72)
                .foregroundStyle(.orange)
            Text(TodayGreeting.title(now: now, calendar: greetingCalendar, fullName: fullName))
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            if showsBrief {
                Text(headline)
                    .font(.system(size: 19))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Under the stat strip: where the day's emails were processed, when the run finished and a link to the
/// suggestions still waiting from earlier days.
struct TodayRunLine: View {
    let info: RunInfo?
    let calendar: Calendar
    /// Suggestions from earlier days that are not on this screen.
    let waitingCount: Int
    let openReviewQueue: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let info {
                if let processing = RunLine.processingText(info) {
                    Label(processing, systemImage: info.cloudEmails > 0 ? "lock.open.fill" : "lock.fill")
                        .labelStyle(RunLineLabelStyle())
                }
                if let timing = RunLine.timingText(info, calendar: calendar) {
                    Text(timing).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if waitingCount > 0 {
                Button("\(waitingCount) more waiting from earlier days", action: openReviewQueue)
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                    .help("Open the Review Queue")
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

/// The four stat tiles. To Review, Worth Knowing and Skipped scroll to their section when clicked.
struct TodayStatStrip: View {
    let emailsRead: Int
    let toReview: Int
    let worthKnowing: Int
    let skipped: Int
    /// Opens the Skipped disclosure before the scroll, so the section is on screen when it arrives.
    var onShowSkipped: () -> Void = {}

    @Environment(\.scrollToSection) private var scrollTo

    static let reviewID = "section-review"
    static let infoID = "section-info"
    static let skippedID = "section-skipped"

    var body: some View {
        StatStrip(stats: [
            .init(value: "\(emailsRead)", caption: "Emails Read"),
            .init(value: "\(toReview)", caption: "To Review", isAccent: true,
                  action: toReview > 0 ? { scrollTo(Self.reviewID) } : nil),
            .init(value: "\(worthKnowing)", caption: "Worth Knowing",
                  action: worthKnowing > 0 ? { scrollTo(Self.infoID) } : nil),
            .init(value: "\(skipped)", caption: "Skipped",
                  action: skipped > 0 ? { onShowSkipped(); scrollTo(Self.skippedID) } : nil),
        ])
    }
}

private struct RunLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

#if DEBUG
#Preview("Today header and run line") {
    let calendar = PreviewSupport.calendar
    let info = RunInfo(localEmails: 8, cloudEmails: 0, localModel: "qwen3:4b", cloudModel: nil,
                       finishedAt: PreviewFixtures.now, duration: 46 * 60)
    VStack(alignment: .leading, spacing: 20) {
        TodayHeader(now: PreviewFixtures.now, greetingCalendar: calendar, dateCalendar: calendar, fullName: "Justin Wang",
                    headline: "Two things need a decision: the Tanda AI Hackathon on Friday 20 Nov and Jacob's runsheet.")
        TodayRunLine(info: info, calendar: calendar, waitingCount: 7, openReviewQueue: {})
        TodayRunLine(info: RunInfo(localEmails: 5, cloudEmails: 3, localModel: "qwen3:4b", cloudModel: "gemini-3.5-flash-lite",
                                   finishedAt: PreviewFixtures.now, duration: 3_900),
                     calendar: calendar, waitingCount: 0, openReviewQueue: {})
    }
    .padding(40).frame(width: 800)
}
#endif

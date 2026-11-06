import MailDigestCore
import SwiftUI

/// Mail Cleanup (Q55): the processed-email list for the latest digest, its action bar pinned below, and the
/// Undo toast floating over the bottom.
struct MailCleanupView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var processed: ProcessedMailModel { run.processed }

    var body: some View {
        let count = processed.allEntries.count
        CanvasScaffold(run: run, access: access, title: "Mail Cleanup",
                       subtitle: count == 0 ? nil : "\(count) \(count == 1 ? "email" : "emails") ready to clear") { _ in
            ProcessedListView(model: processed)
        }
        .overlay(alignment: .bottom) {
            UndoToast(model: processed)
                .padding(.bottom, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: processed.lastBatch?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if count > 0 {
                VStack(spacing: 0) {
                    Divider()
                    ProcessedActionBar(model: processed)
                }
                .background(.bar)
            }
        }
    }
}

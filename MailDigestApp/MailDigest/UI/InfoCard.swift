import MailDigestCore
import SwiftUI

/// One email's summary with its key facts and a button that opens it in Mail.
struct InfoCard: View {
    let item: InfoItem
    let email: EmailContext?
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.summary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(item.keyFacts, id: \.self) { fact in
                    Label {
                        Text(fact).font(.caption)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 4))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                }
                if let email {
                    Text("\(ReviewPresentation.senderName(email.sender)) · \(email.subject)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open this email in Mail")
            .accessibilityLabel("Open email in Mail")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Info card") {
    let item = PreviewFixtures.digest.info[0]
    return InfoCard(item: item, email: PreviewFixtures.emails["canvas@qut.example"])
        .padding().frame(width: 560)
}

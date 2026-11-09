import SwiftUI
import MailDigestCore

/// A circle with the sender's initials on a neutral grey gradient, or a local photo when one is supplied.
/// A sender logo replaces the initials once one is ready: first a logo from the mail's own BIMI header, then
/// (only with Show Sender Logos on) one from the sender's website. The circle never changes size meanwhile.
/// The view itself makes no request; the environment's provider decides what may be fetched.
struct SenderAvatar: View {
    enum Size: CGFloat { case small = 28, large = 36 }

    let sender: String
    var size: Size = .large
    /// A photo already available locally (for example from Contacts, supplied by the caller).
    var photo: Image?

    @Environment(\.senderLogos) private var logos
    @State private var logo: NSImage?

    var body: some View {
        ZStack {
            if let photo {
                photo.resizable().scaledToFill()
            } else if let logo {
                Circle().fill(.white)
                Image(nsImage: logo).resizable().scaledToFit().padding(size.rawValue * 0.1)
                Circle().strokeBorder(.separator, lineWidth: 0.5)
            } else {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xBDBDC5), Color(hex: 0x8E8E98)],
                                             startPoint: .top, endPoint: .bottom))
                Text(SenderInitials.make(sender: sender))
                    .font(.system(size: size.rawValue * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .clipShape(Circle())
        .task(id: LogoRequest(sender: sender, network: logos?.networkEnabled ?? false)) {
            logo = await logos?.image(forSender: sender)
        }
        .accessibilityHidden(true) // The sender name is always read from the row's own text.
    }
}

/// Reruns the lookup when the sender or the setting changes.
private struct LogoRequest: Equatable {
    var sender: String
    var network: Bool
}

#Preview("Sender avatars") {
    HStack {
        SenderAvatar(sender: "Philip Fraser <p@x.com>")
        SenderAvatar(sender: "Letterboxd <hi@l.com>", size: .small)
        SenderAvatar(sender: "justin@example.com")
        SenderAvatar(sender: "", size: .small)
    }
    .padding()
}

import SwiftUI
import MailDigestCore

/// A circle with the sender's initials on a neutral grey gradient, or a local photo when one is supplied.
/// It never loads anything from the network.
struct SenderAvatar: View {
    enum Size: CGFloat { case small = 28, large = 36 }

    let sender: String
    var size: Size = .large
    /// A photo already available locally (for example from Contacts, supplied by the caller).
    var photo: Image?

    var body: some View {
        ZStack {
            if let photo {
                photo.resizable().scaledToFill()
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
        .accessibilityHidden(true) // The sender name is always read from the row's own text.
    }
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

import AppKit
import MailDigestCore
import SwiftUI

/// Supplies sender logos to `SenderAvatar` through the environment. Where none is injected (previews,
/// snapshots) the avatar shows initials and nothing is loaded or fetched.
@MainActor @Observable
final class SenderLogoProvider {
    private let service: SenderLogoService?
    private let networkSetting: @MainActor () -> Bool
    /// Decoded images by origin and domain, so a list of rows decodes each logo once.
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()

    init(service: SenderLogoService?, networkSetting: @escaping @MainActor () -> Bool) {
        self.service = service
        self.networkSetting = networkSetting
        cache.countLimit = 300
    }

    /// Whether website logos may be fetched and shown. Reads the observable setting, so views using it
    /// as a task id reload when the switch changes.
    var networkEnabled: Bool { service != nil && networkSetting() }

    /// Header logo, then (when the setting is on) website logo; nil means show initials.
    func image(forSender sender: String) async -> NSImage? {
        guard let service, let domain = SenderDomain.foldedDomain(fromSender: sender) else { return nil }
        let network = networkEnabled
        let key = "\(network ? "n" : "l")/\(domain)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let logo = await service.logo(forSender: sender, networkEnabled: network),
              let image = LogoImageDecoder.image(for: logo) else { return nil }
        // The setting changed while this ran: drop the result; the avatar's task has already restarted.
        if network != networkEnabled { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

extension EnvironmentValues {
    /// Nil (the default, used by previews and snapshots) means no logos and no fetches.
    @Entry var senderLogos: SenderLogoProvider?
}

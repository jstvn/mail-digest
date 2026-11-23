import Darwin
import Foundation
import MailDigestCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads what this Mac can do (Q100): the chip and Apple Intelligence's state. Cheap, so callers evaluate it
/// again when Settings appears and before each run, because Apple Intelligence can be switched on while the
/// app is running.
enum HostPlatformDetector {
    /// The current platform. Detection is by capability, not by chip name.
    static func current() -> HostPlatform {
        HostPlatform(isAppleSilicon: isAppleSilicon, foundationModels: foundationModelsAvailability())
    }

    /// `hw.optional.arm64` is 1 on Apple silicon, also for a process running under Rosetta.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    static func foundationModelsAvailability() -> FoundationModelsAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
                case .modelNotReady: return .unavailable(.modelNotReady)
                @unknown default: return .unavailable(.other)
                }
            }
        }
        #endif
        return .unavailable(.unsupportedOS)
    }
}

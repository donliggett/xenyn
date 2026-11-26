import Foundation

enum XenynError: LocalizedError {
    case coreAudio(OSStatus, String)
    case audio(String)
    case mic(String)
    case clip(String)
    case graillonMissing

    var errorDescription: String? {
        switch self {
        case let .coreAudio(status, step):
            return "Core Audio error \(status) while trying to \(step)."
        case let .audio(message), let .mic(message), let .clip(message):
            return message
        case .graillonMissing:
            return "Graillon isn't installed (or macOS hasn't registered it yet; try logging out and back in)."
        }
    }
}

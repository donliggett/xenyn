import AppKit
import AVFoundation

struct Clip: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String { id.deletingPathExtension().lastPathComponent }
}

/// Audio files in the clips folder, decoded on demand into buffers that match an engine's format.
final class ClipLibrary {
    static let folder: URL = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Xenyn/Clips", isDirectory: true)

    static let extensions: Set<String> = ["wav", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac"]

    private var cache: [String: AVAudioPCMBuffer] = [:]

    func scan() -> [Clip] {
        cache.removeAll()
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Clip(id: $0) }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.folder])
    }

    func buffer(for clip: Clip, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let key = "\(clip.url.path)#\(format.sampleRate)#\(format.channelCount)"
        if let cached = cache[key] { return cached }
        let buffer = try Self.decode(clip.url, to: format)
        cache[key] = buffer
        return buffer
    }

    private static func decode(_ url: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XenynError.clip("\(url.lastPathComponent) is empty.")
        }
        try file.read(into: input)

        guard let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw XenynError.clip("Can't convert \(url.lastPathComponent).")
        }
        if inFormat.channelCount == 1 && format.channelCount == 2 {
            converter.channelMap = [0, 0]   // mono clip → both ears
        }

        let ratio = format.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw XenynError.clip("Out of memory decoding \(url.lastPathComponent).")
        }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw error ?? XenynError.clip("Couldn't decode \(url.lastPathComponent).")
        }
        return output
    }
}

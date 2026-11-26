import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures everything the Mac is playing (the caller, on a FaceTime call) with ScreenCaptureKit,
/// excluding Xenyn's own audio, and feeds it into a RingBuffer. Used only for recording.
/// Needs Screen Recording permission.
final class SystemAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate {
    private let ring: RingBuffer
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "xenyn.system-audio", qos: .userInteractive)
    private var stream: SCStream?

    /// Called on the main queue if capture stops on its own.
    var onStop: ((Error) -> Void)?

    init(sampleRate: Double, ring: RingBuffer) {
        self.sampleRate = sampleRate
        self.ring = ring
        super.init()
    }

    /// Completion runs on the main queue.
    func start(completion: @escaping (Error?) -> Void) {
        let finish: (Error?) -> Void = { error in DispatchQueue.main.async { completion(error) } }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else {
                finish(error ?? XenynError.audio("No display available for system audio capture."))
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(self.sampleRate)
            config.channelCount = 1
            // Audio only: keep the (required) video side as small and slow as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                finish(error)
                return
            }
            stream.startCapture { error in
                if error == nil { self.stream = stream }
                finish(error)
            }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        ring.write(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?(error) }
    }
}

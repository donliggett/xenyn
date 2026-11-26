import AVFoundation
import CoreMedia

struct MicOption: Identifiable, Hashable {
    let id: String   // AVCaptureDevice.uniqueID
    let name: String
}

/// Something feeding a RingBuffer that can be stopped.
protocol AudioCapture: AnyObject {
    func stop()
}

/// Captures one input device with AVCaptureSession and feeds mono float samples into a RingBuffer.
///
/// AVCaptureSession is used instead of AVAudioEngine's input node so the input can be any
/// device, independent of the device the call audio is sent to.
final class MicCapture: NSObject, AudioCapture, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "xenyn.mic", qos: .userInteractive)
    private let ring: RingBuffer

    init(device: AVCaptureDevice, sampleRate: Double, ring: RingBuffer) throws {
        self.ring = ring
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw XenynError.mic("Can't use \(device.localizedName) as an input.")
        }
        session.addInput(input)

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw XenynError.mic("Can't read audio from \(device.localizedName).")
        }
        session.addOutput(output)
    }

    func start() {
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.sync { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        ring.write(sampleBuffer)
    }

    private static func allDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// Microphones the user can pick. Virtual BlackHole devices are excluded to avoid feedback.
    static func options() -> [MicOption] {
        allDevices()
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("BlackHole") }
            .map { MicOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Inputs that can carry the caller's audio for recording. BlackHole 2ch is excluded:
    /// it carries Xenyn's own output.
    static func callerOptions() -> [MicOption] {
        allDevices()
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("BlackHole 2ch") }
            .map { MicOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The system default mic, unless it's BlackHole; otherwise the first real mic.
    static func defaultOptionID() -> String? {
        if let device = AVCaptureDevice.default(for: .audio),
           !device.localizedName.localizedCaseInsensitiveContains("BlackHole") {
            return device.uniqueID
        }
        return options().first?.id
    }
}

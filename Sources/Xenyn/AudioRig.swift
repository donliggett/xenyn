import AVFoundation
import AudioToolbox

enum VoiceKind: String, CaseIterable, Identifiable {
    case builtIn = "Built-in pitch"
    case graillon = "Graillon"
    var id: String { rawValue }
}

/// Where the caller's audio comes from when recording.
enum CallerSource: Hashable {
    case systemAudio            // ScreenCaptureKit
    case device(String)         // an input device's uniqueID, e.g. BlackHole 16ch
}

/// The audio graph.
///
///   mic ─► ring ─► source ─► upmix ─► voice ─► voiceOut ─┐
///                                                        ├─► callMix ─┬─► main mixer ─► BlackHole 2ch
///                                   clipPlayer ──────────┘            │        ▲
///                                                                     ▼        │ (silent)
///   caller (system audio) ─► callerRing ─► callerSource ─────► recordMixer ─► recordSink
///                                                               └─ tap ─► .m4a
///
///   monitorPlayer ─► main mixer ─► default output (headphones)
///
/// Each AVAudioEngine is bound to exactly one output device, and inputs arrive through
/// AVCaptureSession / ScreenCaptureKit, so no aggregate device is needed. The caller's audio
/// only reaches the recording: recordSink is muted, so it never goes back into the call.
final class AudioRig {
    private let callEngine = AVAudioEngine()
    private let monitorEngine = AVAudioEngine()

    private let ring = RingBuffer(capacity: 96_000)
    private var mic: MicCapture?
    private var source: AVAudioSourceNode?
    private let upmix = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private(set) var graillon: AVAudioUnit?
    private lazy var activeVoice: AVAudioUnit = timePitch
    private let voiceOut = AVAudioMixerNode()
    private let clipPlayer = AVAudioPlayerNode()
    private let callMix = AVAudioMixerNode()
    private let monitorPlayer = AVAudioPlayerNode()

    private let callerRing = RingBuffer(capacity: 96_000)
    private var callerSource: AVAudioSourceNode?
    private var callerCapture: AudioCapture?
    private let recordMixer = AVAudioMixerNode()
    private let recordSink = AVAudioMixerNode()

    private var callFormat: AVAudioFormat?
    private var monitorFormat: AVAudioFormat?
    private var configured = false
    private var playToken = 0

    private(set) var monitorAvailable = false
    private(set) var recordingURL: URL?

    /// Called on the main queue when a clip finishes on its own (not when stopped).
    var onClipFinished: (() -> Void)?

    var micEnabled = true { didSet { applyVoiceLevel() } }
    var micGain: Float = 1 { didSet { applyVoiceLevel() } }
    var voiceEnabled = true { didSet { activeVoice.auAudioUnit.shouldBypassEffect = !voiceEnabled } }
    var pitchSemitones: Float = -4 { didSet { timePitch.pitch = pitchSemitones * 100 } }
    var clipGain: Float = 0.8 { didSet { clipPlayer.volume = clipGain } }
    var monitorOn = true { didSet { if !monitorOn && monitorAvailable { monitorPlayer.stop() } } }
    var monitorGain: Float = 0.8 { didSet { monitorPlayer.volume = monitorGain } }

    var isRunning: Bool { callEngine.isRunning }

    // MARK: Setup

    /// Builds the graph once. `callDevice` is where the mix goes (BlackHole 2ch).
    func configure(callDevice: AudioDevice) throws {
        guard !configured else { return }

        try AudioDevices.bind(callEngine, to: callDevice.id)
        let rate = callEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0,
              let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw XenynError.audio("Couldn't read the sample rate of \(callDevice.name).")
        }
        callFormat = stereo
        ring.reset(target: Int(rate * 0.04))   // ~40 ms of mic latency headroom

        let source = Self.sourceNode(format: mono, reading: ring)
        let callerSource = Self.sourceNode(format: mono, reading: callerRing)
        self.source = source
        self.callerSource = callerSource

        for node in [source, upmix, timePitch, voiceOut, clipPlayer, callMix,
                     callerSource, recordMixer, recordSink] as [AVAudioNode] {
            callEngine.attach(node)
        }
        let main = callEngine.mainMixerNode

        // Your side: mic → voice effect, plus clips.
        callEngine.connect(source, to: upmix, format: mono)
        callEngine.connect(upmix, to: timePitch, format: stereo)
        callEngine.connect(timePitch, to: voiceOut, format: stereo)
        callEngine.connect(voiceOut, to: callMix, format: stereo)
        callEngine.connect(clipPlayer, to: callMix, format: stereo)

        // Your side goes to the call and to the recording.
        callEngine.connect(callMix, to: [
            AVAudioConnectionPoint(node: main, bus: main.nextAvailableInputBus),
            AVAudioConnectionPoint(node: recordMixer, bus: recordMixer.nextAvailableInputBus),
        ], fromBus: 0, format: stereo)

        // Caller's side goes to the recording only. recordSink is muted but keeps the branch rendering.
        callEngine.connect(callerSource, to: recordMixer, format: mono)
        callEngine.connect(recordMixer, to: recordSink, format: stereo)
        callEngine.connect(recordSink, to: main, format: stereo)
        recordSink.outputVolume = 0

        timePitch.pitch = pitchSemitones * 100
        clipPlayer.volume = clipGain
        applyVoiceLevel()

        // Monitor on the system output, unless that output is BlackHole itself.
        if let output = AudioDevices.defaultOutput(), output != callDevice.id {
            let monitorRate = monitorEngine.outputNode.outputFormat(forBus: 0).sampleRate
            if monitorRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: monitorRate, channels: 2) {
                monitorEngine.attach(monitorPlayer)
                monitorEngine.connect(monitorPlayer, to: monitorEngine.mainMixerNode, format: format)
                monitorPlayer.volume = monitorGain
                monitorFormat = format
                monitorAvailable = true
            }
        }

        configured = true
    }

    /// A mono source node that pulls from a ring buffer on the render thread.
    private static func sourceNode(format: AVAudioFormat, reading ring: RingBuffer) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                guard let data = buffer.mData else { continue }
                ring.read(into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            }
            return noErr
        }
    }

    func start(mic device: AVCaptureDevice?) throws {
        if !callEngine.isRunning {
            callEngine.prepare()
            try callEngine.start()
        }
        if monitorAvailable && !monitorEngine.isRunning {
            monitorEngine.prepare()
            try? monitorEngine.start()   // monitoring is optional; the call path matters
        }
        if let device { try switchMic(to: device) }
    }

    func switchMic(to device: AVCaptureDevice) throws {
        guard let rate = callFormat?.sampleRate else { return }
        mic?.stop()
        mic = nil
        let capture = try MicCapture(device: device, sampleRate: rate, ring: ring)
        ring.reset(target: Int(rate * 0.04))
        capture.start()
        mic = capture
    }

    func stop() {
        _ = stopRecording()
        stopClips()
        mic?.stop()
        mic = nil
        callEngine.stop()
        monitorEngine.stop()
    }

    // MARK: Voice

    private func applyVoiceLevel() {
        voiceOut.outputVolume = micEnabled ? micGain : 0
    }

    func useVoice(_ kind: VoiceKind) throws {
        let next: AVAudioUnit
        switch kind {
        case .builtIn:
            next = timePitch
        case .graillon:
            guard let graillon else { throw XenynError.graillonMissing }
            next = graillon
        }
        guard next !== activeVoice, let format = callFormat else { return }

        let wasRunning = callEngine.isRunning
        callEngine.stop()
        callEngine.disconnectNodeOutput(upmix)
        callEngine.disconnectNodeOutput(activeVoice)
        callEngine.connect(upmix, to: next, format: format)
        callEngine.connect(next, to: voiceOut, format: format)
        activeVoice = next
        activeVoice.auAudioUnit.shouldBypassEffect = !voiceEnabled
        if wasRunning {
            callEngine.prepare()
            try callEngine.start()
        }
    }

    static func findGraillon() -> AVAudioUnitComponent? {
        let anything = AudioComponentDescription(
            componentType: 0, componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        return AVAudioUnitComponentManager.shared().components(matching: anything).first {
            let type = $0.audioComponentDescription.componentType
            return (type == kAudioUnitType_Effect || type == kAudioUnitType_MusicEffect)
                && $0.name.localizedCaseInsensitiveContains("Graillon")
        }
    }

    /// Instantiates Graillon (once) and attaches it to the call engine. Completion runs on main.
    func loadGraillon(completion: @escaping (Error?) -> Void) {
        if graillon != nil { completion(nil); return }
        guard let component = Self.findGraillon() else { completion(XenynError.graillonMissing); return }

        AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self, let unit else {
                    completion(error ?? XenynError.graillonMissing)
                    return
                }
                self.callEngine.attach(unit)
                self.graillon = unit
                completion(nil)
            }
        }
    }

    // MARK: Clips

    func play(_ clip: Clip, from library: ClipLibrary) throws {
        guard let format = callFormat, callEngine.isRunning else {
            throw XenynError.audio("Audio isn't running yet.")
        }
        let buffer = try library.buffer(for: clip, format: format)

        playToken &+= 1
        let token = playToken
        clipPlayer.stop()
        if monitorAvailable { monitorPlayer.stop() }

        clipPlayer.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playToken == token else { return }
                self.onClipFinished?()
            }
        }
        clipPlayer.play()

        if monitorOn, monitorAvailable, monitorEngine.isRunning, let monitorFormat {
            let monitorBuffer = try library.buffer(for: clip, format: monitorFormat)
            monitorPlayer.scheduleBuffer(monitorBuffer, at: nil, options: [], completionHandler: nil)
            monitorPlayer.play()
        }
    }

    // MARK: Recording

    /// Records both sides of the call to an AAC .m4a: your side (voice + clips) and the caller.
    /// Completion runs on the main queue.
    func startRecording(to url: URL, caller: CallerSource, completion: @escaping (Error?) -> Void) {
        guard recordingURL == nil else { completion(nil); return }
        guard callEngine.isRunning, let rate = callFormat?.sampleRate else {
            completion(XenynError.audio("Audio isn't running yet."))
            return
        }
        callerRing.reset(target: Int(rate * 0.04))

        let beginWriting: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.installRecordingTap(url: url)
                completion(nil)
            } catch {
                self.callerCapture?.stop()
                self.callerCapture = nil
                completion(error)
            }
        }

        switch caller {
        case .systemAudio:
            let capture = SystemAudioCapture(sampleRate: rate, ring: callerRing)
            capture.start { [weak self] error in
                guard let self else { return }
                if let error {
                    completion(XenynError.audio(
                        "Couldn't capture the caller's audio (\(error.localizedDescription)). "
                        + "Allow Xenyn under System Settings → Privacy & Security → Screen Recording."))
                    return
                }
                self.callerCapture = capture
                beginWriting()
            }
        case let .device(id):
            do {
                guard let device = AVCaptureDevice(uniqueID: id) else {
                    throw XenynError.audio("The caller-audio input is no longer connected.")
                }
                let capture = try MicCapture(device: device, sampleRate: rate, ring: callerRing)
                capture.start()
                callerCapture = capture
                beginWriting()
            } catch {
                completion(error)
            }
        }
    }

    private func installRecordingTap(url: URL) throws {
        let format = recordMixer.outputFormat(forBus: 0)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 160_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        // The tap owns the file; removing the tap releases it, which finalizes the .m4a.
        recordMixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
        recordingURL = url
    }

    /// Stops recording and returns the finished file, if one was being written.
    func stopRecording() -> URL? {
        guard let url = recordingURL else { return nil }
        recordMixer.removeTap(onBus: 0)
        callerCapture?.stop()
        callerCapture = nil
        recordingURL = nil
        return url
    }

    func stopClips() {
        playToken &+= 1   // invalidates pending completion callbacks
        guard configured else { return }
        clipPlayer.stop()
        if monitorAvailable { monitorPlayer.stop() }
    }
}

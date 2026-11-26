import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CoreAudioKit

/// App state and actions. All methods are called on the main thread
/// (SwiftUI, Carbon hotkeys and rig callbacks all deliver there).
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Status
    @Published private(set) var status = "Starting…"
    @Published private(set) var live = false
    @Published private(set) var graillonAvailable = false
    @Published private(set) var monitorAvailable = false

    // Voice
    @Published private(set) var micOptions: [MicOption] = []
    @Published var micID = "" { didSet { if micID != oldValue { switchMic() } } }
    @Published var micEnabled = true { didSet { rig.micEnabled = micEnabled } }
    @Published var micGain = 1.0 { didSet { rig.micGain = Float(micGain) } }
    @Published var voiceEnabled = true { didSet { rig.voiceEnabled = voiceEnabled } }
    @Published var voiceKind: VoiceKind = .builtIn { didSet { if voiceKind != oldValue { applyVoiceKind() } } }
    @Published var pitchSemitones = -4.0 { didSet { rig.pitchSemitones = Float(pitchSemitones) } }

    // Clips
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var playingID: Clip.ID?
    @Published var clipGain = 0.8 { didSet { rig.clipGain = Float(clipGain) } }
    @Published private(set) var rambleOn = false
    @Published var rambleGap = 3.0   // average seconds between rambled clips

    // Record
    static let systemAudioID = "system-audio"
    @Published private(set) var recording = false
    @Published private(set) var callerOptions: [MicOption] = []
    @Published var callerSourceID = AppModel.systemAudioID
    static let recordingsFolder: URL = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Xenyn/Recordings", isDirectory: true)

    // Monitor
    @Published var monitorOn = true { didSet { rig.monitorOn = monitorOn } }
    @Published var monitorGain = 0.8 { didSet { rig.monitorGain = Float(monitorGain) } }

    private let rig = AudioRig()
    private let library = ClipLibrary()
    private let hotKeys = HotKeys()
    private var rambleWork: DispatchWorkItem?
    private var lastRambled: Clip.ID?
    private var pluginWindow: NSWindow?

    private init() {
        rig.onClipFinished = { [weak self] in self?.clipFinished() }
        graillonAvailable = AudioRig.findGraillon() != nil
        micOptions = MicCapture.options()
        micID = MicCapture.defaultOptionID() ?? ""
        callerOptions = Self.callerChoices()
        reloadClips()
        registerHotKeys()
    }

    // MARK: Lifecycle

    func start() {
        guard let blackHole = AudioDevices.blackHole2ch() else {
            status = "BlackHole 2ch not found. Install it, then press Retry."
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.status = "Microphone access denied. Allow Xenyn in System Settings → Privacy & Security → Microphone."
                    return
                }
                do {
                    try self.rig.configure(callDevice: blackHole)
                    try self.rig.start(mic: AVCaptureDevice(uniqueID: self.micID))
                    self.monitorAvailable = self.rig.monitorAvailable
                    self.live = true
                    self.status = "Live → \(blackHole.name)"
                } catch {
                    self.live = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func shutdown() {
        setRamble(false)
        rig.stop()
    }

    private func switchMic() {
        guard live, let device = AVCaptureDevice(uniqueID: micID) else { return }
        do { try rig.switchMic(to: device) } catch { status = error.localizedDescription }
    }

    func refreshMics() {
        callerOptions = Self.callerChoices()
        if !callerOptions.contains(where: { $0.id == callerSourceID }) {
            callerSourceID = Self.systemAudioID
        }
        micOptions = MicCapture.options()
        if !micOptions.contains(where: { $0.id == micID }) {
            micID = MicCapture.defaultOptionID() ?? ""
        }
    }

    // MARK: Voice

    private func applyVoiceKind() {
        switch voiceKind {
        case .builtIn:
            do { try rig.useVoice(.builtIn) } catch { status = error.localizedDescription }
        case .graillon:
            rig.loadGraillon { [weak self] error in
                guard let self else { return }
                do {
                    if let error { throw error }
                    try self.rig.useVoice(.graillon)
                } catch {
                    self.status = error.localizedDescription
                    self.voiceKind = .builtIn
                }
            }
        }
    }

    func openGraillonEditor() {
        guard let unit = rig.graillon else { status = XenynError.graillonMissing.localizedDescription; return }
        if let pluginWindow { pluginWindow.makeKeyAndOrderFront(nil); return }
        unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let controller else { self.status = "Graillon didn't provide an editor."; return }
                let window = NSWindow(contentViewController: controller)
                window.title = "Graillon"
                window.styleMask = [.titled, .closable, .miniaturizable]
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                self.pluginWindow = window
            }
        }
    }

    func toggleMic() { micEnabled.toggle() }
    func toggleVoice() { voiceEnabled.toggle() }

    /// Stop everything fake: clips off, ramble off, effect bypassed. Mic stays live.
    func panic() {
        setRamble(false)
        stopClips()
        voiceEnabled = false
    }

    // MARK: Record

    private static func callerChoices() -> [MicOption] {
        [MicOption(id: systemAudioID, name: "System audio")] + MicCapture.callerOptions()
    }

    private var callerSource: CallerSource {
        callerSourceID == Self.systemAudioID ? .systemAudio : .device(callerSourceID)
    }

    private var startingRecording = false

    func toggleRecording() {
        if recording {
            recording = false
            if let url = rig.stopRecording() {
                status = "Saved \(url.lastPathComponent)"
            }
            return
        }
        guard !startingRecording else { return }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        } catch {
            status = error.localizedDescription
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let url = Self.recordingsFolder.appendingPathComponent("Xenyn \(formatter.string(from: Date())).m4a")

        startingRecording = true
        rig.startRecording(to: url, caller: callerSource) { [weak self] error in
            guard let self else { return }
            self.startingRecording = false
            if let error {
                self.status = error.localizedDescription
            } else {
                self.recording = true
                self.status = "Recording…"
            }
        }
    }

    func revealRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.recordingsFolder])
    }

    // MARK: Clips

    func reloadClips() {
        stopClips()
        clips = library.scan()
    }

    func revealClipsFolder() { library.revealFolder() }

    func play(_ clip: Clip) {
        do {
            try rig.play(clip, from: library)
            playingID = clip.id
        } catch {
            status = error.localizedDescription
        }
    }

    func play(index: Int) {
        guard clips.indices.contains(index) else { return }
        play(clips[index])
    }

    /// Stops the current clip and ramble mode.
    func stopClips() {
        rambleOn = false
        rambleWork?.cancel()
        rig.stopClips()
        playingID = nil
    }

    func setRamble(_ on: Bool) {
        rambleOn = on
        rambleWork?.cancel()
        if on && playingID == nil { rambleNext() }
    }

    private func rambleNext() {
        guard rambleOn, !clips.isEmpty else { return }
        let pool = clips.count > 1 ? clips.filter { $0.id != lastRambled } : clips
        guard let clip = pool.randomElement() else { return }
        lastRambled = clip.id
        play(clip)
    }

    private func clipFinished() {
        playingID = nil
        guard rambleOn else { return }
        let delay = rambleGap * Double.random(in: 0.6...1.4)
        let work = DispatchWorkItem { [weak self] in self?.rambleNext() }
        rambleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Hotkeys  (⌃⌥ + key)

    private func registerHotKeys() {
        let mods = controlKey | optionKey
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digits.enumerated() {
            hotKeys.register(keyCode: key, modifiers: mods) { [weak self] in self?.play(index: index) }
        }
        hotKeys.register(keyCode: kVK_ANSI_0, modifiers: mods) { [weak self] in self?.stopClips() }
        hotKeys.register(keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            guard let self else { return }
            self.setRamble(!self.rambleOn)
        }
        hotKeys.register(keyCode: kVK_ANSI_M, modifiers: mods) { [weak self] in self?.toggleMic() }
        hotKeys.register(keyCode: kVK_ANSI_V, modifiers: mods) { [weak self] in self?.toggleVoice() }
        hotKeys.register(keyCode: kVK_ANSI_E, modifiers: mods) { [weak self] in self?.toggleRecording() }
        hotKeys.register(keyCode: kVK_Space, modifiers: mods) { [weak self] in self?.panic() }
    }
}

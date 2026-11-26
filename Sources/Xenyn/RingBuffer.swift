import CoreMedia
import Foundation
import os

/// Mono float FIFO between the microphone capture queue and the audio render thread.
///
/// The mic and the output device run on different clocks, so the buffer slowly fills
/// or drains. It handles that by dropping old audio when too far ahead and re-priming
/// (outputting silence) when it runs dry.
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readPos = 0
    private var writePos = 0
    private var filled = 0
    private var primed = false
    private var target: Int

    init(capacity: Int, target: Int = 2048) {
        self.capacity = capacity
        self.target = min(target, capacity / 2)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    /// Clears the buffer and sets the latency (in frames) it tries to hold.
    func reset(target newTarget: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        readPos = 0
        writePos = 0
        filled = 0
        primed = false
        target = max(64, min(newTarget, capacity / 2))
    }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }

        let count = min(frames, capacity)
        let start = frames - count
        for i in 0..<count {
            storage[writePos] = source[start + i]
            writePos = (writePos + 1) % capacity
        }
        filled += count

        // Overflow, or drifted too far ahead: drop the oldest audio.
        let ceiling = min(capacity, target * 4)
        if filled > ceiling {
            let drop = filled - target
            readPos = (readPos + drop) % capacity
            filled = target
        }
    }

    /// Writes channel 0 of a Float32 PCM sample buffer (from AVCaptureSession or ScreenCaptureKit).
    func write(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

            if channels == 1 || !interleaved {
                // Mono, or non-interleaved where the first buffer is channel 0.
                write(samples, frames: count)
            } else {
                let frames = count / channels
                var mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames { mono[i] = samples[i * channels] }
                mono.withUnsafeBufferPointer { write($0.baseAddress!, frames: frames) }
            }
        }
    }

    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }

        if !primed {
            guard filled >= target else {
                destination.initialize(repeating: 0, count: frames)
                return
            }
            primed = true
        }

        let count = min(frames, filled)
        for i in 0..<count {
            destination[i] = storage[readPos]
            readPos = (readPos + 1) % capacity
        }
        filled -= count

        if count < frames {
            (destination + count).initialize(repeating: 0, count: frames - count)
            primed = false
        }
    }
}

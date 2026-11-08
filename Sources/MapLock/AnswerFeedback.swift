import AVFoundation
import os
import SwiftUI

/// A short right-or-wrong note. It fades on its own and never takes clicks.
struct PenaltyPop: Equatable {
    var token: Int
    var text: String
}

struct AnswerChip: Equatable {
    var token: Int
    var right: Bool
    var title: String
}

enum MapLockTrace {
    static let log = Logger(subsystem: "com.elliot.maplock", category: "speedrun")
    static let signpost = OSSignposter(logger: log)
}

/// Long-lived engine. The first `NSSound.play` used to start Core Audio on the main thread
/// and froze the app for seconds. This warms up on a background queue and skips if it is not ready.
enum AnswerSound {
    private static let queue = DispatchQueue(label: "com.elliot.maplock.audio", qos: .userInitiated)
    private static let state = NSLock()
    private static var engine: AVAudioEngine?
    private static var rightNode: AVAudioPlayerNode?
    private static var wrongNode: AVAudioPlayerNode?
    private static var rightBuffer: AVAudioPCMBuffer?
    private static var wrongBuffer: AVAudioPCMBuffer?
    private static var isReady = false
    private static var warming = false

    /// Call once at launch. Safe to call again. Never touches the audio graph on the main thread.
    static func warmUp() {
        queue.async { warmUpOnQueue() }
    }

    static func play(correct: Bool) {
        guard AppSettings().answerSounds else { return }
        play(nodeIsRight: correct, volume: correct ? 1 : 0.45)
    }

    /// A quiet note for a race challenge. Skipped when answer sounds are off.
    static func playSoft() {
        guard AppSettings().answerSounds else { return }
        play(nodeIsRight: true, volume: 0.22)
    }

    private static func play(nodeIsRight: Bool, volume: Float) {
        state.lock()
        let ready = isReady
        state.unlock()
        guard ready else { return }
        queue.async {
            let node = nodeIsRight ? rightNode : wrongNode
            let buffer = nodeIsRight ? rightBuffer : wrongBuffer
            guard let node, let buffer, engine?.isRunning == true else { return }
            node.volume = volume
            node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !node.isPlaying { node.play() }
        }
    }

    private static func warmUpOnQueue() {
        state.lock()
        if isReady || warming {
            state.unlock()
            return
        }
        warming = true
        state.unlock()
        let engine = AVAudioEngine()
        let rightNode = AVAudioPlayerNode()
        let wrongNode = AVAudioPlayerNode()
        guard let right = loadBuffer("Tink"), let wrong = loadBuffer("Basso") else { return }
        engine.attach(rightNode)
        engine.attach(wrongNode)
        engine.connect(rightNode, to: engine.mainMixerNode, format: right.format)
        engine.connect(wrongNode, to: engine.mainMixerNode, format: wrong.format)
        do {
            try engine.start()
        } catch {
            MapLockTrace.log.error("audio warmup failed")
            return
        }
        if let silent = AVAudioPCMBuffer(pcmFormat: right.format, frameCapacity: 64) {
            silent.frameLength = 64
            rightNode.scheduleBuffer(silent, completionHandler: nil)
            rightNode.play()
        }
        state.lock()
        self.engine = engine
        self.rightNode = rightNode
        self.wrongNode = wrongNode
        self.rightBuffer = right
        self.wrongBuffer = wrong
        self.isReady = true
        state.unlock()
        MapLockTrace.log.info("audio warmed")
    }

    private static func loadBuffer(_ name: String) -> AVAudioPCMBuffer? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return buffer
    }
}

struct AnswerChipBanner: View {
    let chip: AnswerChip
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chip.right ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
            Text(chip.title)
                .font(Theme.font(Theme.Size.sm, .bold))
                .lineLimit(1)
        }
        .foregroundStyle(chip.right ? Theme.good : Theme.bad)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill((chip.right ? Theme.good : Theme.bad).opacity(0.16))
        )
        .offset(y: shown || reduceMotion ? 0 : -10)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityLabel(chip.title)
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.easeOut(duration: 0.18)) { shown = true }
            }
        }
    }
}

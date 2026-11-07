import AppKit
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

enum AnswerSound {
    static func play(correct: Bool) {
        guard AppSettings().answerSounds else { return }
        let name = correct ? "Tink" : "Basso"
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = correct ? 0.5 : 0.22
        sound.play()
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

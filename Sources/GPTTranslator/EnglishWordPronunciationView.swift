import AVFoundation
import SwiftUI

struct EnglishWordPronunciationView: View {
    let text: String
    let language: LanguageOption

    @State private var entry: Entry?
    @State private var voiceUnavailable = false

    private struct Entry {
        let word: EnglishWord
        let pronunciations: [String]
    }

    private var word: EnglishWord? {
        guard language == .auto || language == .english else { return nil }
        return EnglishWord(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entry, entry.word == word {
                if entry.pronunciations.isEmpty {
                    pronunciationRow(entry.word, ipa: nil, distinguishReadings: false)
                } else {
                    ForEach(entry.pronunciations, id: \.self) { ipa in
                        pronunciationRow(entry.word, ipa: ipa, distinguishReadings: entry.pronunciations.count > 1)
                    }
                }
                if voiceUnavailable {
                    Text("美式英语语音不可用，可在系统设置的「阅读与朗读」中添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: word) {
            voiceUnavailable = false
            guard let word else {
                entry = nil
                return
            }
            let pronunciations = await EnglishPronunciationDictionary.shared.pronunciations(for: word)
            guard !Task.isCancelled else { return }
            entry = Entry(word: word, pronunciations: pronunciations)
        }
    }

    private func pronunciationRow(_ word: EnglishWord, ipa: String?, distinguishReadings: Bool) -> some View {
        HStack(spacing: 8) {
            Text("美式")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: ipa ?? "未收录音标")
                .textSelection(.enabled)
            Button {
                voiceUnavailable = !EnglishWordSpeaker.shared.speak(word, ipa: distinguishReadings ? ipa : nil)
            } label: {
                Label(ipa.map { "朗读 \($0)" } ?? "朗读单词", systemImage: "speaker.wave.2")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("播放美式发音")
        }
        .font(.callout)
    }
}

@MainActor
private final class EnglishWordSpeaker {
    static let shared = EnglishWordSpeaker()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ word: EnglishWord, ipa: String?) -> Bool {
        let preferredVoice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" && $0.quality != .default }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        guard let voice = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US") else { return false }
        let utterance: AVSpeechUtterance
        if let ipa {
            let notation = String(ipa.dropFirst().dropLast())
            let text = NSAttributedString(string: word.text, attributes: [
                NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute): notation
            ])
            utterance = AVSpeechUtterance(attributedString: text)
        } else {
            utterance = AVSpeechUtterance(string: word.text)
        }
        utterance.voice = voice
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        return true
    }
}

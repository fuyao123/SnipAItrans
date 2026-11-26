import Foundation

struct EnglishWord: Equatable, Sendable {
    let text: String

    var dictionaryKey: String { text.lowercased() }

    init?(_ text: String) {
        let edges = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,!?;:…。，！？；：()[]{}<>“”‘’\"'"))
        let word = text.trimmingCharacters(in: edges)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‑", with: "-")
        guard word.utf8.count <= 64,
              word.range(of: #"^[A-Za-z]+(?:['-][A-Za-z]+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        self.text = word
    }
}

actor EnglishPronunciationDictionary {
    static let shared = EnglishPronunciationDictionary()
    private let sourceURL: URL?
    private lazy var entries = loadEntries()

    init(sourceURL: URL? = nil) {
        self.sourceURL = sourceURL
    }

    func pronunciations(for word: EnglishWord) -> [String] {
        entries[word.dictionaryKey] ?? []
    }

    private func loadEntries() -> [String: [String]] {
        guard let url = sourceURL ?? Self.bundledURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var dictionary = [String: [String]]()
        for line in contents.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 1)
            guard columns.count == 2 else { continue }
            let pronunciations = columns[1].components(separatedBy: ", ").filter {
                $0.hasPrefix("/") && $0.hasSuffix("/") && $0.count > 2
            }
            if !pronunciations.isEmpty {
                dictionary[String(columns[0])] = pronunciations
            }
        }
        return dictionary
    }

    private static var bundledURL: URL? {
        if let url = Bundle.main.url(forResource: "AmericanEnglishIPA", withExtension: "txt") {
            return url
        }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "AmericanEnglishIPA", withExtension: "txt")
        #else
        return nil
        #endif
    }
}

import Foundation
@preconcurrency import Translation

// Integration check on a Mac with the English and Chinese packs installed.
@main
struct AppleTranslationChecks {
    @MainActor static func main() async throws {
        guard #available(macOS 15, *) else { print("Skipped: macOS 15 required"); return }
        let availability = LanguageAvailability()
        let englishToChinese = await availability.status(
            from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans")
        )
        guard englishToChinese == .installed else { print("Skipped: English-Chinese packs not installed"); return }
        let service = AppleTranslationService()
        for text in ["bevacizumab", "pembrolizumab", "LaunchAgent"] {
            let result = try await service.translate(text: text, source: .auto, target: .chineseSimplified)
            precondition(!result.isEmpty, "Empty result for \(text)")
        }
        let chineseToEnglish = await availability.status(
            from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en")
        )
        if chineseToEnglish == .installed {
            let result = try await service.translate(text: "所以", source: .auto, target: .english)
            precondition(!result.isEmpty, "Short Chinese translation failed")
        }
        let spanishToChinese = await availability.status(
            from: Locale.Language(identifier: "es"), to: Locale.Language(identifier: "zh-Hans")
        )
        if spanishToChinese != .installed {
            do {
                _ = try await service.translate(text: "hola", source: .spanish, target: .chineseSimplified)
                fatalError("Explicit Spanish was incorrectly replaced with English")
            } catch AppleTranslationService.ServiceError.languagePackNotInstalled(let source, _) {
                precondition(source == "Español")
            }
            do {
                _ = try await service.translate(text: "el paciente recibe tratamiento", source: .auto, target: .chineseSimplified)
                fatalError("Confident Spanish was incorrectly replaced with English")
            } catch AppleTranslationService.ServiceError.languagePackNotInstalled(let source, _) {
                precondition(source == "Español")
            }
        }
        print("Apple translation language checks passed")
    }
}

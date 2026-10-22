import Foundation

/// The app a person sees running the VM: Try Omarchy, or the app that embeds
/// its kit. The run mode passes it to the launcher and the bridges.
enum ProductName {
    static let environmentKey = "OMARCHY_PRODUCT_NAME"
    static let defaultName = "Try Omarchy"

    static var current: String {
        ProcessInfo.processInfo.environment[environmentKey].flatMap(validated) ?? defaultName
    }

    static func validated(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(trimmed.count), trimmed == name,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }
}

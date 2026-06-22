import Foundation

/// Human-readable byte formatting. Mirrors Go `utils.FormatSize`.
enum Format {
    private static let kb: Double = 1024
    private static let mb: Double = 1024 * kb
    private static let gb: Double = 1024 * mb

    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= gb {
            return String(format: "%.1f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", value / mb)
        }
        if value >= kb {
            return String(format: "%.1f KB", value / kb)
        }
        return "\(bytes) B"
    }

    /// True when path has a `.pdf` extension (case-insensitive). Mirrors Go `utils.IsPDF`.
    static func isPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }
}

import Foundation
import PDFKit
import AppKit
import Vision
import CoreImage

/// OCR fallback for invoices whose PDF text layer is unreadable.
///
/// Some electronic-invoice PDFs are produced by buggy generators that draw
/// text as vector glyphs (so `PDFPage.string` is nil) or invert the colour
/// scheme (black background, white text). Vision OCR handles both — but
/// only after we render the page to an image and detect/invert the colours
/// when the page is mostly dark.
///
/// Produces `[Token]` in the same coordinate convention as the text-layer
/// path, so the existing `parse(lines:)` logic is reused unchanged.
enum InvoiceOCR {

    // Tunables (extracted from inline magic numbers).
    private static let renderScale: CGFloat = 4.0      // 4x for legible small digits
    private static let darkSampleGrid: Int = 40         // pixels per axis for invert detection
    private static let darkPixelThreshold: Double = 0.5 // brightness below this = "dark"
    private static let invertedRatioThreshold: Double = 0.5 // >50% dark → treat as inverted

    /// One OCR-recognised text fragment with its bounding box (normalised,
    /// origin BOTTOM-left, as Vision reports).
    struct OCRToken {
        let normX: CGFloat      // left edge, 0..1
        let normY: CGFloat      // line's vertical centre, 0..1
        let s: String
    }

    /// Run OCR on every page of `doc`, returning tokens ready to be turned
    /// into `Line`s. Returns nil if OCR yields nothing usable.
    ///
    /// Safe to call off the main actor: rendering goes through a CGContext
    /// (not `NSImage.lockFocus`, which is main-thread-only).
    ///
    /// `progress` is invoked per page with (pageIndex, pageCount) so callers
    /// can report progress; it runs on an arbitrary queue.
    static func recognise(doc: PDFDocument,
                          progress: ((Int, Int) -> Void)? = nil) -> [OCRToken]? {
        var allTokens: [OCRToken] = []
        let pageCount = doc.pageCount
        for i in 0..<pageCount {
            // Cooperative cancellation — a cancelled Task aborts here.
            if Task.isCancelled { return allTokens.isEmpty ? nil : allTokens }
            progress?(i, pageCount)
            guard let page = doc.page(at: i) else { continue }
            guard let cgImage = renderAndPrep(page: page) else { continue }
            guard let tokens = recognise(cgImage: cgImage) else { continue }
            allTokens.append(contentsOf: tokens)
        }
        return allTokens.isEmpty ? nil : allTokens
    }

    // MARK: - Rendering (thread-safe)

    /// Render a PDF page to a CGImage at `renderScale`, inverting colours
    /// when the page is mostly dark (some invoice PDFs are black-on-white
    /// reversed). Thread-safe: uses CGContext directly, not NSImage.lockFocus.
    private static func renderAndPrep(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = renderScale
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        // ARGB bitmap context — can be created on any thread.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // White background (PDF pages expect to draw onto paper).
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)

        guard let cg = ctx.makeImage() else { return nil }

        // Detect inverted (dark) page → invert via CIColorInvert.
        if shouldInvert(cgImage: cg, width: width, height: height) {
            return invert(cgImage: cg)
        }
        return cg
    }

    /// Sample a grid of pixels from the CGImage to decide if it's mostly
    /// dark (an inverted/black-background page). Operates directly on the
    /// bitmap bytes — no NSImage / NSBitmapImageRep needed, so it's thread-safe.
    private static func shouldInvert(cgImage: CGImage, width: Int, height: Int) -> Bool {
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let bytesPerRow = cgImage.bytesPerRow
        let bpp = cgImage.bitsPerPixel / 8
        let grid = darkSampleGrid
        let stepX = max(1, width / grid), stepY = max(1, height / grid)
        var dark = 0, total = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * bpp
                if offset + 2 < CFDataGetLength(data) {
                    // Use Rec. 601 luma as a cheap brightness proxy.
                    let r = Double(ptr[offset])
                    let g = Double(ptr[offset + 1])
                    let b = Double(ptr[offset + 2])
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    if luma / 255.0 < darkPixelThreshold { dark += 1 }
                    total += 1
                }
                x += stepX
            }
            y += stepY
        }
        return total > 0 && Double(dark) / Double(total) > invertedRatioThreshold
    }

    private static func invert(cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorInvert") else { return cgImage }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return cgImage }
        return CIContext().createCGImage(output, from: output.extent)
    }

    // MARK: - Vision

    /// Recognise text on a CGImage, returning OCR tokens with normalised
    /// bottom-left origin coordinates.
    private static func recognise(cgImage: CGImage) -> [OCRToken]? {
        var out: [OCRToken] = []
        let req = VNRecognizeTextRequest { request, _ in
            guard let results = request.results as? [VNRecognizedTextObservation] else { return }
            for obs in results {
                guard let s = obs.topCandidates(1).first?.string,
                      !s.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let box = obs.boundingBox   // normalised, bottom-left origin
                out.append(OCRToken(normX: box.minX, normY: box.midY, s: s))
            }
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // Language correction tends to "correct" isolated digits (e.g. turn
        // "2000.00" into a date). Off gives more literal numeric output.
        req.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        return out.isEmpty ? nil : out
    }
}

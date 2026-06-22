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
    /// `progress` is invoked per page with (pageIndex, pageCount) so callers
    /// can report progress; it runs on an arbitrary queue.
    static func recognise(doc: PDFDocument,
                          progress: ((Int, Int) -> Void)? = nil) -> [OCRToken]? {
        var allTokens: [OCRToken] = []
        let pageCount = doc.pageCount
        for i in 0..<pageCount {
            progress?(i, pageCount)
            guard let page = doc.page(at: i) else { continue }
            guard let image = render(page: page) else { continue }
            let maybeInverted = shouldInvert(image) ? invert(image) : image
            guard let cg = toCGImage(maybeInverted) else { continue }
            guard let tokens = recognise(cgImage: cg, pageHeight: maybeInverted.size.height) else { continue }
            allTokens.append(contentsOf: tokens)
        }
        return allTokens.isEmpty ? nil : allTokens
    }

    // MARK: - Rendering

    /// Render a PDF page to an NSImage at 4x for legible small digits.
    private static func render(page: PDFPage) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let img = NSImage(size: size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
        img.unlockFocus()
        return img
    }

    /// A page is "inverted" (black background) when most sampled pixels are
    /// dark. Sampling a grid is enough — full-pixel scans are slow.
    private static func shouldInvert(_ image: NSImage) -> Bool {
        guard let rep = bitmapRep(image) else { return false }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return false }
        var dark = 0, total = 0
        let stepX = max(1, w / 40), stepY = max(1, h / 40)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 {
                    dark += 1
                }
                x += stepX
            }
            y += stepY
        }
        // A normal page is ~95% white. Treat >50% dark as inverted.
        return total > 0 && Double(dark) / Double(total) > 0.5
    }

    private static func invert(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorInvert") else {
            return image
        }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else {
            return image
        }
        return NSImage(cgImage: cg, size: image.size)
    }

    private static func toCGImage(_ image: NSImage) -> CGImage? {
        guard let rep = bitmapRep(image) else { return nil }
        return rep.cgImage
    }

    private static func bitmapRep(_ image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.first as? NSBitmapImageRep { return rep }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    // MARK: - Vision

    /// Recognise text on a CGImage, returning OCR tokens with normalised
    /// bottom-left origin coordinates. `pageHeight` is currently unused
    /// (coords stay normalised) but kept for clarity.
    private static func recognise(cgImage: CGImage, pageHeight: CGFloat) -> [OCRToken]? {
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

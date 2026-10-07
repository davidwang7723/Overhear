import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit
import Vision

/// Screen access for vision: a JPEG grab for the vision model at answer time,
/// and cheap Neural-Engine OCR for the periodic on-screen text context.
/// Everything is on-demand and fully local.
final class ScreenCaptureService {
    private let ciContext = CIContext()

    // MARK: - Raw capture

    private func captureImage(target: CaptureTarget,
                              maxWidth: CGFloat) async -> CGImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            NSLog("Overhear shareable content FAILED: \(error)")
            return nil
        }
        guard let display = content.displays.first else {
            NSLog("Overhear: no displays in shareable content")
            return nil
        }

        let filter: SCContentFilter
        let sourceWidth: CGFloat
        if target == .frontmostWindow, let window = frontmostWindow(in: content) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = window.frame.width
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceWidth = CGFloat(display.width)
        }

        let config = SCStreamConfiguration()
        let scale = min(1, maxWidth / max(sourceWidth, 1))
        let pixelScale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * pixelScale * scale)
        config.height = Int(filter.contentRect.height * pixelScale * scale)
        config.showsCursor = false

        guard config.width > 0, config.height > 0 else { return nil }
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            NSLog("Overhear screenshot FAILED: \(error)")
            return nil
        }
    }

    // MARK: - For the vision model (answer time)

    /// JPEG base64 (no data-URI prefix — Ollama wants raw base64). nil on failure.
    func captureBase64(target: CaptureTarget = .fullDisplay,
                       maxWidth: CGFloat = 1280, quality: CGFloat = 0.6) async -> String? {
        guard let cgImage = await captureImage(target: target, maxWidth: maxWidth)
        else { return nil }
        let ci = CIImage(cgImage: cgImage)
        guard let data = ciContext.jpegRepresentation(
                of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
        else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - For periodic context (cheap, no GPU)

    /// OCR the whole screen with Apple's Vision framework — runs on the Neural
    /// Engine in ~milliseconds, no vision-LLM GPU pass. Returns the on-screen
    /// text plus a hash so callers can skip unchanged screens.
    func captureText(maxWidth: CGFloat = 2000) async -> (text: String, hash: Int)? {
        guard let cgImage = await captureImage(target: .fullDisplay, maxWidth: maxWidth)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch {
            NSLog("Overhear OCR FAILED: \(error)")
            return nil
        }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        NSLog("Overhear OCR: \(request.results?.count ?? 0) lines, \(text.count) chars")
        return (text, text.hashValue)
    }

    // MARK: -

    /// The largest on-screen window of the frontmost app (what the user is
    /// looking at — shared slides, a coding window, a problem statement).
    private func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return content.windows
            .filter { $0.isOnScreen && $0.owningApplication?.processID != ownPID }
            .filter { frontPID == nil || $0.owningApplication?.processID == frontPID }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

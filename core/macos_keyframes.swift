import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import Vision

func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    print(String(decoding: data, as: UTF8.self))
}

func quality(_ image: CGImage) -> Double {
    let side = 64
    var gray = [UInt8](repeating: 0, count: side * side)
    gray.withUnsafeMutableBytes { pixels in
        guard let context = CGContext(data: pixels.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
        else { return }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    var edges = 0
    var clipped = 0
    for (i, pixel) in gray.enumerated() {
        if pixel < 20 || pixel > 235 { clipped += 1 }
        if i % side > 0 { edges += abs(Int(pixel) - Int(gray[i - 1])) }
        if i >= side { edges += abs(Int(pixel) - Int(gray[i - side])) }
    }
    return Double(edges) / Double(gray.count) * (1 - 0.9 * Double(clipped) / Double(gray.count))
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
if #available(macOS 12.0, *), let supported = try? request.supportedRecognitionLanguages() {
    let preferred = ["zh-Hans", "en-US"].filter { supported.contains($0) }
    if !preferred.isEmpty { request.recognitionLanguages = preferred }
}

func recognize(_ image: CGImage) -> [String] {
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    } catch {
        return []
    }
}

let arguments = CommandLine.arguments
if arguments[1] == "ocr" {
    var output: [String: [String]] = [:]
    for path in arguments.dropFirst(2) {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let image = NSBitmapImageRep(data: data)?.cgImage {
            output[path] = recognize(image)
        }
    }
    try emit(output)
    exit(0)
}

let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[2]))
let duration = CMTimeGetSeconds(asset.duration)
guard duration.isFinite, duration > 0, let track = asset.tracks(withMediaType: .video).first else { exit(2) }

if arguments[1] == "probe" {
    let size = track.naturalSize.applying(track.preferredTransform)
    try emit(["duration_s": duration, "width": Int(abs(size.width.rounded())),
              "height": Int(abs(size.height.rounded()))])
    exit(0)
}

let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
let plan = try JSONDecoder().decode([String: [Double]].self, from: Data(arguments[4].utf8))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 640, height: 640)
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

var output: [String: [[String: Any]]] = [:]
for (stage, timestamps) in plan {
    var images: [(index: Int, time: Double, image: CGImage, score: Double)] = []
    for (index, seconds) in timestamps.enumerated() {
        var actual = CMTime.invalid
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        if let image = try? generator.copyCGImage(at: target, actualTime: &actual) {
            let timestamp = CMTimeGetSeconds(actual)
            if timestamp.isFinite { images.append((index, timestamp, image, quality(image))) }
        }
    }
    output[stage] = images.compactMap { candidate in
        let path = directory.appendingPathComponent("\(stage)-\(candidate.index).jpg")
        let bitmap = NSBitmapImageRep(cgImage: candidate.image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              (try? jpeg.write(to: path)) != nil else { return nil }
        return ["path": path.path, "timestamp_s": candidate.time, "sharpness_score": candidate.score,
                "ocr_texts": recognize(candidate.image)]
    }
}
try emit(output)

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
#if canImport(Speech)
import Speech
#endif

public protocol MediaRecognizing: Sendable {
    func detectMediaKind(for url: URL?) -> MediaKind
    func recognizeMedia(
        mediaURL: URL?,
        spokenTranscript: String,
        sourceDevice: String,
        hintOverrides: VisualFieldReadings?,
        extractFrames: Bool
    ) async -> RecognitionOutput
}

public final class AppleOnDeviceMediaRecognizer: MediaRecognizing {
    public static let audioOnlyExtensions: Set<String> = [
        "m4a", "wav", "mp3", "aac", "caf", "ogg", "oga", "flac", "opus", "aif", "aiff",
    ]

    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp",
    ]

    public static let coffeeContextualStrings: [String] = [
        "开始录制", "开始录像", "我要开始制作咖啡", "开始制作咖啡", "开始做咖啡",
        "停止录制", "结束录制", "停止录像", "结束录像", "制作完成", "咖啡做好了",
        "格米莱", "Gemilai", "G3828A", "3828", "CRM3605", "CRM3005", "CRM3145", "G3007L", "云象", "豆仓",
        "百胜图", "Barsetto", "2sAP", "BAE02S", "BAE01", "BAE02",
        "小米咖啡机", "米家咖啡机", "Xiaomi", "Mijia",
        "佩罗奇", "佩洛奇", "PELOQI", "佩罗奇S1",
        "马克西姆", "MOKKOM", "塞纳", "马赛", "鲶鱼", "巴洛克", "变压模式",
        "德龙", "De'Longhi", "Delonghi", "Dedica", "EC685", "EC885", "EC9355", "EC9865",
        "咸芝士低因", "SOE", "深烘", "烘焙度",
        "耶加雪菲", "瑰夏", "埃塞俄比亚", "哥伦比亚", "肯尼亚", "巴拿马",
        "电子秤", "压粉锤", "布粉器", "布粉针", "接粉环", "无底手柄", "蒸汽棒", "奶缸", "单孔意式机",
        "粉量", "液重", "研磨度", "刻度", "水温", "萃取", "手冲", "滤杯", "摩卡壶", "爱乐压", "冷萃", "拿铁", "拉花", "奶泡", "打奶泡", "Dirty",
        "Niche Zero", "EK43", "DF64", "Breville", "Bialetti", "V60",
        "espresso", "pour over", "latte", "crema", "portafilter", "tamper", "grinder", "extraction", "grams", "seconds", "yield", "dose", "ratio",
    ]

    private struct StageSpec: Sendable {
        let fraction: Double
        let key: String
        let label: String
        let windowLow: Double
        let windowHigh: Double
        let fallbackTimestamp: Double
        let descriptionTemplate: String
    }

    private static let stageSpecs: [StageSpec] = [
        StageSpec(
            fraction: 0.08,
            key: "scale_dose",
            label: "称重豆量 (Weighing Beans)",
            windowLow: 0.02,
            windowHigh: 0.16,
            fallbackTimestamp: 6.0,
            descriptionTemplate: "电子秤称重咖啡豆与豆袋画面"
        ),
        StageSpec(
            fraction: 0.20,
            key: "grinding",
            label: "磨豆与出粉 (Grinding & Dosing)",
            windowLow: 0.14,
            windowHigh: 0.28,
            fallbackTimestamp: 16.0,
            descriptionTemplate: "磨豆机刻度盘与磨豆出粉画面"
        ),
        StageSpec(
            fraction: 0.32,
            key: "dose_weigh",
            label: "接粉称重 (Grounds Weight)",
            windowLow: 0.26,
            windowHigh: 0.40,
            fallbackTimestamp: 26.0,
            descriptionTemplate: "手柄接粉与电子秤复称出粉量画面"
        ),
        StageSpec(
            fraction: 0.44,
            key: "wdt_distribute",
            label: "布粉针打散结块 (WDT)",
            windowLow: 0.38,
            windowHigh: 0.52,
            fallbackTimestamp: 36.0,
            descriptionTemplate: "WDT 布粉针打散咖啡粉结块特写"
        ),
        StageSpec(
            fraction: 0.56,
            key: "leveler_flatten",
            label: "布粉器压平 (Leveling)",
            windowLow: 0.50,
            windowHigh: 0.64,
            fallbackTimestamp: 46.0,
            descriptionTemplate: "布粉器旋转整平粉层表面特写"
        ),
        StageSpec(
            fraction: 0.68,
            key: "tamping",
            label: "压粉锤压粉 (Tamping)",
            windowLow: 0.62,
            windowHigh: 0.76,
            fallbackTimestamp: 56.0,
            descriptionTemplate: "压粉锤垂直恒力压实粉饼特写"
        ),
        StageSpec(
            fraction: 0.80,
            key: "pressure_crema",
            label: "咖啡机萃取与油脂 (Extraction)",
            windowLow: 0.74,
            windowHigh: 0.88,
            fallbackTimestamp: 68.0,
            descriptionTemplate: "意式机压力表与手柄萃取油脂流态"
        ),
        StageSpec(
            fraction: 0.92,
            key: "yield_timer",
            label: "出杯液重与成品 (Final Yield)",
            windowLow: 0.86,
            windowHigh: 0.98,
            fallbackTimestamp: 84.0,
            descriptionTemplate: "萃取结束电子秤读秒与出杯成品特写"
        ),
    ]

    private static let stageKeywordPatterns: [String: String] = [
        "scale_dose": "咖啡豆|豆子|豆量|烘焙度|称重|称豆|浅烘|中烘|深烘|水洗|日晒|耶加|瑰夏|埃塞|(?<!磨)豆(?!仓)",
        "grinding": "磨豆|出粉|研磨|刻度|刀盘|豆仓|牌子|niche|ek43|weber|df64|comandante|自带磨豆|3828|格米莱|格莱米",
        "dose_weigh": "接粉|出粉量|粉量|粉重|复称|粉碗|接粉环|基本环",
        "wdt_distribute": "布粉针|打散|结块|wdt|松粉",
        "leveler_flatten": "布粉器|压平|找平|整平|旋转布粉",
        "tamping": "压粉锤|鸭粉锤|压粉|压实|恒力|回弹|粉饼",
        "pressure_crema": "压力|(?<![a-z])bar(?![a-z])|巴(?!拿马)|水温|(?<!刻)度|预浸泡|流速|油脂|虎斑|无底|手柄|萃取",
        "yield_timer": "液重|出液|出杯|秒|一整套|制作的工具|完成|成品",
    ]

    private static let stopPattern = "萃取完成|做好了|停止|结束"
    private static let numberPattern = #"(?<![0-9a-zA-Z.+:：-])(\d+(?:\.\d+)?)(?![\d.:：])"#
    private static let beanOriginPattern = #"耶加雪菲|瑰夏|埃塞俄比亚|哥伦比亚|肯尼亚|巴拿马|咸芝士低因|咸[芝共][士主]低因|\bSOE\b|拼配"#
    private static let grinderModels: [String] = [
        "Niche Zero", "Niche", "EK43", "DF64", "DF83", "Lagom", "Breville", "Sage",
        "Mazzer", "Weber", "Comandante", "Bialetti", "De'Longhi", "DeLonghi", "Dedica",
        "Rancilio", "Lelit", "La Marzocco", "Flair", "Barsetto", "Timemore", "1Zpresso",
        "Fellow", "Kinu", "Hario", "MHW-3BOMBER", "Gemilai", "PELOQI", "MOKKOM", "Xiaomi", "Mijia",
    ]

    private let keyframeBaseDirectory: URL
    private let localeIdentifier: String
    private let knownBeans: [BeanEntry]

    public init(
        keyframeBaseDirectory: URL? = nil,
        localeIdentifier: String = "zh-CN",
        knownBeans: [BeanEntry] = []
    ) {
        if let dir = keyframeBaseDirectory {
            self.keyframeBaseDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.keyframeBaseDirectory = docs
                .appendingPathComponent("PocketCoffeeData", isDirectory: true)
                .appendingPathComponent("Keyframes", isDirectory: true)
        }
        self.localeIdentifier = localeIdentifier
        self.knownBeans = knownBeans
    }

    public static func onDeviceSpeechAvailable() -> Bool {
        #if canImport(Speech)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
        #else
        return false
        #endif
    }

    public static let maxCaptureDeviceLength = 64
    public static let maxInputImageDimension = 16_384
    public static let maxOCRWorkingDimension = 2_560
    public static let maxUpscaledPixels = 2_073_600

    /// Sanitizes untrusted camera/device strings (from QuickTime/MP4 metadata or client inputs):
    /// strips control characters, newlines, and Unicode BiDi overrides, rejects embedded URLs,
    /// filesystem paths, and ISO-6709 GPS coordinates (`+31.23+121.47/`), and enforces a 64-char cap.
    public static func sanitizeCaptureDeviceName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let slice = String(raw.prefix(256))
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(slice.unicodeScalars.count, 128))
        for scalar in slice.unicodeScalars {
            let v = scalar.value
            // Strip ASCII/C1 control characters (including \0, \r, \n, \t) and Unicode BiDi/invisible formatting
            if v < 0x20 || (0x7F...0x9F).contains(v) {
                if v == 0x09 || v == 0x0A || v == 0x0D {
                    scalars.append(" ")
                }
                continue
            }
            if (0x200B...0x200F).contains(v)
                || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v)
                || v == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        // Reject filesystem paths, URL schemes, or ISO-6709 GPS coordinate strings
        if collapsed.hasPrefix("/")
            || collapsed.hasPrefix("~")
            || collapsed.contains("..")
            || collapsed.contains("://")
            || collapsed.contains("\\") {
            return nil
        }
        if !regexMatches(pattern: #"^[+-]\d{1,3}(?:\.\d+)?[+-]\d{1,3}(?:\.\d+)?"#, in: collapsed).isEmpty {
            return nil
        }

        let capped = String(collapsed.prefix(maxCaptureDeviceLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    private static func applySandboxProtectionIfNeeded(at url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    public static func extractCaptureDevice(from url: URL) async -> String? {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        return await extractCaptureDevice(from: asset)
    }

    public static func extractCaptureDevice(from asset: AVAsset) async -> String? {
        var allItems: [AVMetadataItem] = []
        if let rootMeta = try? await asset.load(.metadata) {
            allItems.append(contentsOf: rootMeta.prefix(64))
        }
        if allItems.count < 64, let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats.prefix(8) where allItems.count < 64 {
                if let items = try? await asset.loadMetadata(for: format) {
                    allItems.append(contentsOf: items.prefix(64 - allItems.count))
                }
            }
        }
        guard !allItems.isEmpty else { return nil }

        var makeValue: String?
        var modelValue: String?
        var softwareValues: [String] = []

        for item in allItems.prefix(64) {
            let rawID = (item.identifier?.rawValue ?? "").lowercased()
            let commonKey = item.commonKey
            // Never read or propagate location / GPS metadata atoms
            if commonKey == .commonKeyLocation
                || rawID.contains("location")
                || rawID.contains("gps")
                || rawID.contains("iso6709")
                || rawID.contains("©xyz") {
                continue
            }
            guard let rawString = try? await item.load(.stringValue) else { continue }
            guard let val = sanitizeCaptureDeviceName(String(rawString.prefix(256))) else { continue }

            if commonKey == .commonKeyMake || rawID.hasSuffix(".make") || rawID.contains("©mak") {
                if makeValue == nil { makeValue = val }
            } else if commonKey == .commonKeyModel || rawID.hasSuffix(".model") || rawID.contains("©mod") {
                if modelValue == nil { modelValue = val }
            } else if softwareValues.count < 8 && (
                commonKey == .commonKeySoftware
                || rawID.hasSuffix(".software")
                || rawID.contains("©too")
                || rawID.contains("encoder")
                || rawID.contains("dji")
                || rawID.contains("gopro")
                || rawID.contains("insta360")
            ) {
                softwareValues.append(val)
            }
        }

        if let model = modelValue, !model.isEmpty {
            if let make = makeValue, !make.isEmpty {
                let lowerMake = make.lowercased()
                let lowerModel = model.lowercased()
                // Apple models like "iPhone 15 Pro" / "iPad Pro" are cleaner without redundant "Apple " prefix
                if lowerMake == "apple" && (lowerModel.hasPrefix("iphone") || lowerModel.hasPrefix("ipad") || lowerModel.hasPrefix("mac")) {
                    return sanitizeCaptureDeviceName(model)
                }
                if !lowerModel.hasPrefix(lowerMake) {
                    return sanitizeCaptureDeviceName("\(make) \(model)")
                }
            }
            return sanitizeCaptureDeviceName(model)
        }

        // Fallback: inspect encoder / software / manufacturer tags (common on DJI Pocket / Action / GoPro / Insta360)
        let joinedExtra = String(([makeValue].compactMap { $0 } + softwareValues).joined(separator: " ").prefix(512))
        let knownPatterns: [(pattern: String, canonical: String?)] = [
            (#"(?i)dji[\s_-]{0,4}(?:osmo[\s_-]{0,4})?pocket[\s_-]{0,4}4[\s_-]{0,4}pro\b"#, "DJI Osmo Pocket 4 Pro"),
            (#"(?i)dji[\s_-]{0,4}(?:osmo[\s_-]{0,4})?pocket[\s_-]{0,4}4\b"#, "DJI Osmo Pocket 4"),
            (#"(?i)dji[\s_-]{0,4}(?:osmo[\s_-]{0,4})?pocket[\s_-]{0,4}3\b"#, "DJI Osmo Pocket 3"),
            (#"(?i)dji[\s_-]{0,4}(?:osmo[\s_-]{0,4})?action[\s_-]{0,4}\d{1,2}(?:\s{0,3}pro)?\b"#, nil),
            (#"(?i)gopro[\s_-]{0,4}hero\s{0,3}\d{1,2}(?:\s{0,3}black)?\b"#, nil),
            (#"(?i)insta360(?:[\s_-]{1,3}[a-z0-9]{1,16}){1,4}\b"#, nil),
            (#"(?i)iphone\s{0,3}\d{1,2}(?:\s{1,3}(?:pro\s{1,2}max|pro|plus|mini|air))?\b"#, nil),
            (#"(?i)ipad(?:\s{1,3}(?:pro|air|mini))?\b"#, nil),
        ]
        for (pattern, canonical) in knownPatterns {
            if let match = regexMatches(pattern: pattern, in: joinedExtra).first,
               let range = Range(match.range, in: joinedExtra) {
                if let canonical { return canonical }
                return sanitizeCaptureDeviceName(String(joinedExtra[range]))
            }
        }

        if let make = makeValue, !make.isEmpty {
            return sanitizeCaptureDeviceName(make)
        }
        return nil
    }

    public func detectMediaKind(for url: URL?) -> MediaKind {
        guard let url else { return .text }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty && url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text
        }
        let ext = url.pathExtension.lowercased()
        if Self.audioOnlyExtensions.contains(ext) {
            return .audio
        }
        if Self.videoExtensions.contains(ext) {
            return .video
        }
        return .video
    }

    public func recognizeMedia(
        mediaURL: URL?,
        spokenTranscript: String = "",
        sourceDevice: String = "iPhone 手机录制",
        hintOverrides: VisualFieldReadings? = nil,
        extractFrames: Bool = true
    ) async -> RecognitionOutput {
        let mediaKind = detectMediaKind(for: mediaURL)
        let cleanedSpoken = String(spokenTranscript.prefix(20_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeInputDevice = Self.sanitizeCaptureDeviceName(sourceDevice) ?? "iPhone 手机录制"

        // Text-only input
        guard let mediaURL, mediaKind != .text else {
            return RecognitionOutput(
                mediaKind: .text,
                mediaPath: nil,
                sourceDevice: safeInputDevice,
                audioTranscript: "",
                transcript: cleanedSpoken,
                speechSegments: [],
                visualFields: hintOverrides ?? VisualFieldReadings(),
                keyframes: [],
                durationS: nil
            )
        }

        let isReachableLocal = mediaURL.isFileURL && FileManager.default.fileExists(atPath: mediaURL.path)
        var durationS: Double?
        var audioTranscript = ""
        var speechSegments: [SpeechSegment] = []
        var resolvedSourceDevice = safeInputDevice

        if isReachableLocal {
            let asset = AVURLAsset(url: mediaURL)
            if let detectedDevice = await Self.extractCaptureDevice(from: asset) {
                resolvedSourceDevice = detectedDevice
            }
            if let loadedDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(loadedDuration)
                if seconds.isFinite && seconds > 0 {
                    durationS = (seconds * 1000).rounded() / 1000
                }
            }
            let (asrText, asrSegments) = await transcribeAudioOnDevice(asset: asset, mediaURL: mediaURL, durationS: durationS)
            audioTranscript = asrText
            speechSegments = asrSegments
        }

        let combinedTranscript: String
        if audioTranscript.isEmpty {
            combinedTranscript = cleanedSpoken
        } else if cleanedSpoken.isEmpty {
            combinedTranscript = audioTranscript
        } else if cleanedSpoken.contains(audioTranscript) {
            combinedTranscript = cleanedSpoken
        } else {
            combinedTranscript = "\(audioTranscript) \(cleanedSpoken)".trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Audio-only: skip video keyframe extraction cleanly
        if mediaKind == .audio {
            return RecognitionOutput(
                mediaKind: .audio,
                mediaPath: mediaURL.path,
                sourceDevice: resolvedSourceDevice,
                audioTranscript: audioTranscript,
                transcript: combinedTranscript,
                speechSegments: speechSegments,
                visualFields: hintOverrides ?? VisualFieldReadings(),
                keyframes: [],
                durationS: durationS
            )
        }

        // Video: extract keyframes + Vision OCR + Vision scene tags
        var visualFields = hintOverrides ?? VisualFieldReadings()
        var keyframes: [KeyframeObservation] = []
        var visualSceneTags: [String] = []

        if isReachableLocal {
            let (extractedFrames, ocrReadings, sceneTags) = await extractKeyframesAndOCR(
                mediaURL: mediaURL,
                durationS: durationS,
                speechSegments: speechSegments,
                sourceDevice: resolvedSourceDevice,
                extractFrames: extractFrames
            )
            keyframes = extractedFrames
            visualSceneTags = sceneTags
            // OCR values fill in fields; explicit hintOverrides remain if OCR did not find them,
            // matching Python's merge order (hints -> OCR -> explicit overrides when needed).
            visualFields = visualFields.merged(overridingWith: ocrReadings)
            if let hints = hintOverrides {
                // Preserve any explicit hint if OCR didn't detect it; hints take base, OCR updates.
                _ = hints
            }
        }

        return RecognitionOutput(
            mediaKind: .video,
            mediaPath: mediaURL.isFileURL ? mediaURL.path : mediaURL.absoluteString,
            sourceDevice: resolvedSourceDevice,
            audioTranscript: audioTranscript,
            transcript: combinedTranscript,
            speechSegments: speechSegments,
            visualFields: visualFields,
            keyframes: keyframes,
            durationS: durationS,
            visualSceneTags: visualSceneTags
        )
    }

    // MARK: - On-Device Speech Recognition (16s slicing)

    private func transcribeAudioOnDevice(
        asset: AVURLAsset,
        mediaURL: URL,
        durationS: Double?
    ) async -> (String, [SpeechSegment]) {
        #if canImport(Speech)
        guard let totalDuration = durationS, totalDuration > 0 else {
            return ("", [])
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            return ("", [])
        }
        var authStatus = SFSpeechRecognizer.authorizationStatus()
        #if os(iOS)
        if authStatus == .notDetermined {
            authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        if authStatus != .authorized {
            return ("", [])
        }
        #else
        if authStatus == .denied || authStatus == .restricted {
            return ("", [])
        }
        #endif
        guard let primaryRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              primaryRecognizer.supportsOnDeviceRecognition
        else {
            return ("", [])
        }

        let (primaryText, primarySegs) = await runSlicedRecognition(
            recognizer: primaryRecognizer,
            asset: asset,
            mediaURL: mediaURL,
            totalDuration: totalDuration
        )

        // If primary locale (e.g. zh-CN) produced very little text on a spoken clip,
        // automatically probe en-US on-device ASR (at 0s, and if needed at 20s to skip music intros)
        // for English/bilingual coffee videos.
        if primaryText.count < 12,
           localeIdentifier.lowercased() != "en-us",
           let enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
           enRecognizer.supportsOnDeviceRecognition {
            let probeStarts: [Double] = totalDuration > 28.0 ? [0.0, 20.0] : [0.0]
            var enProbeText = ""
            for pStart in probeStarts {
                let probeDur = min(totalDuration - pStart, 16.0)
                guard probeDur >= 2.0 else { continue }
                let probeURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pocket_en_probe_\(UUID().uuidString).m4a")
                if await exportAudioSlice(asset: asset, startSeconds: pStart, durationSeconds: probeDur, outputURL: probeURL) {
                    let (t, _) = await recognizeAudioSlice(
                        recognizer: enRecognizer,
                        url: probeURL,
                        offset: pStart,
                        sliceDuration: probeDur,
                        timeoutSeconds: 7.0
                    )
                    if t.count > enProbeText.count {
                        enProbeText = t
                    }
                }
                try? FileManager.default.removeItem(at: probeURL)
                if enProbeText.count >= max(10, primaryText.count + 6) {
                    break
                }
            }

            if enProbeText.count >= max(10, primaryText.count + 6) {
                let (enText, enSegs) = await runSlicedRecognition(
                    recognizer: enRecognizer,
                    asset: asset,
                    mediaURL: mediaURL,
                    totalDuration: totalDuration
                )
                if enText.count > primaryText.count {
                    return (enText, enSegs)
                }
            }
        }

        return (primaryText, primarySegs)
        #else
        return ("", [])
        #endif
    }

    #if canImport(Speech)
    private func runSlicedRecognition(
        recognizer: SFSpeechRecognizer,
        asset: AVURLAsset,
        mediaURL: URL,
        totalDuration: Double
    ) async -> (String, [SpeechSegment]) {
        let ext = mediaURL.pathExtension.lowercased()
        if totalDuration <= 16.0 && ext != "mp4" && ext != "mov" && ext != "m4v" {
            return await recognizeAudioSlice(
                recognizer: recognizer,
                url: mediaURL,
                offset: 0.0,
                sliceDuration: totalDuration,
                timeoutSeconds: 15.0
            )
        }

        // For video containers or clips > 16s, export 16-second M4A slices so on-device ASR
        // never resets or drops speech across pauses.
        let sliceLen: Double = 16.0
        let cappedDuration: Double = min(totalDuration, 900.0)
        var start: Double = 0.0
        var allTexts: [String] = []
        var allSegments: [SpeechSegment] = []

        while start < cappedDuration - 0.15 {
            let end = min(cappedDuration, start + sliceLen)
            let sliceDuration = end - start
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocket_slice_\(UUID().uuidString)_\(Int(start)).m4a")

            let exported = await exportAudioSlice(
                asset: asset,
                startSeconds: start,
                durationSeconds: sliceDuration,
                outputURL: tmpURL
            )
            if exported {
                let (sliceText, sliceSegs) = await recognizeAudioSlice(
                    recognizer: recognizer,
                    url: tmpURL,
                    offset: start,
                    sliceDuration: sliceDuration,
                    timeoutSeconds: 8.0
                )
                if !sliceText.isEmpty {
                    allTexts.append(sliceText)
                    allSegments.append(contentsOf: sliceSegs)
                }
            }
            try? FileManager.default.removeItem(at: tmpURL)
            start += sliceLen
        }

        return (allTexts.joined(separator: " "), allSegments)
    }
    #endif

    private func exportAudioSlice(
        asset: AVURLAsset,
        startSeconds: Double,
        durationSeconds: Double,
        outputURL: URL
    ) async -> Bool {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )

        if #available(iOS 18.0, macOS 15.0, *) {
            do {
                try await exporter.export(to: outputURL, as: .m4a)
                Self.applySandboxProtectionIfNeeded(at: outputURL)
                return true
            } catch {
                return false
            }
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            await exporter.export()
            if exporter.status == .completed {
                Self.applySandboxProtectionIfNeeded(at: outputURL)
                return true
            }
            return false
        }
    }

    #if canImport(Speech)
    private final class SpeechRecognitionBox: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var bestTranscription: SFTranscription?
        var longestTranscription: SFTranscription?
        var longestLength = 0
        var task: SFSpeechRecognitionTask?
    }

    private func recognizeAudioSlice(
        recognizer: SFSpeechRecognizer,
        url: URL,
        offset: Double,
        sliceDuration: Double,
        timeoutSeconds: Double
    ) async -> (String, [SpeechSegment]) {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = Self.coffeeContextualStrings

        return await withCheckedContinuation { continuation in
            let box = SpeechRecognitionBox()

            let mapSegments: @Sendable (SFTranscription) -> [SpeechSegment] = { transcription in
                let raw = transcription.segments
                guard !raw.isEmpty else { return [] }
                let hasValidTimestamps = raw.contains { $0.timestamp > 0.01 }
                let count = Double(raw.count)
                return raw.enumerated().map { idx, seg in
                    let relTs = hasValidTimestamps
                        ? seg.timestamp
                        : (Double(idx) + 0.5) / count * max(1.0, sliceDuration - 1.0)
                    let dur = seg.duration > 0.01 ? seg.duration : max(0.2, sliceDuration / count)
                    return SpeechSegment(text: seg.substring, timestampS: offset + relTs, durationS: dur)
                }
            }

            let finish: @Sendable () -> Void = {
                box.lock.lock()
                if box.finished {
                    box.lock.unlock()
                    return
                }
                box.finished = true
                let primary = box.longestTranscription ?? box.bestTranscription
                let best = box.bestTranscription
                let taskToCancel = box.task
                box.lock.unlock()

                taskToCancel?.cancel()

                guard let primary, !primary.formattedString.isEmpty else {
                    continuation.resume(returning: ("", []))
                    return
                }
                var combinedText = primary.formattedString
                var segs = mapSegments(primary)
                if let best,
                   !best.formattedString.isEmpty,
                   best.formattedString != combinedText,
                   !combinedText.contains(best.formattedString) {
                    let lastTs = (segs.last?.timestampS ?? offset) - offset
                    let bestMapped = mapSegments(best)
                    let tailSegs = bestMapped.filter { ($0.timestampS - offset) > lastTs + 0.3 }
                    if !tailSegs.isEmpty {
                        combinedText += " " + best.formattedString
                        segs.append(contentsOf: tailSegs)
                    }
                }
                continuation.resume(returning: (combinedText, segs))
            }

            box.task = recognizer.recognitionTask(with: request) { result, error in
                var shouldFinish = false
                box.lock.lock()
                if let result {
                    let t = result.bestTranscription
                    let len = t.formattedString.count
                    if len >= box.longestLength {
                        box.longestLength = len
                        box.longestTranscription = t
                    }
                    if result.isFinal {
                        box.bestTranscription = t
                        shouldFinish = true
                    }
                }
                if error != nil {
                    shouldFinish = true
                }
                box.lock.unlock()

                if shouldFinish {
                    finish()
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                finish()
            }
        }
    }
    #endif

    // MARK: - Dynamic Scene-Change Keyframe Extraction & Evidence-Driven Labeling

    private struct StageWindow {
        let start: Double
        let end: Double
        let center: Double
        let anchored: Bool
    }

    private struct FrameCandidate {
        let image: CGImage
        let timestampS: Double
        let sharpnessScore: Double
        let ocrTexts: [String]
    }

    private struct SceneProbe {
        let image: CGImage
        let timestampS: Double
        let gray64: [UInt8]
        let sharpnessScore: Double
        let transitionDiff: Double
        let ocrTexts: [String]
        let readings: VisualFieldReadings
        let stageKey: String
    }

    /// Computes a 64x64 grayscale signature + sharpness score in a single pass.
    private static func grayscaleSignatureAndSharpness(_ image: CGImage) -> ([UInt8], Double) {
        let side = 64
        var gray = [UInt8](repeating: 0, count: side * side)
        gray.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(
                data: pixels.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: 0
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var edges = 0
        var clipped = 0
        for i in 0..<gray.count {
            let pixel = Int(gray[i])
            if pixel < 20 || pixel > 235 { clipped += 1 }
            if i % side > 0 { edges += abs(pixel - Int(gray[i - 1])) }
            if i >= side { edges += abs(pixel - Int(gray[i - side])) }
        }
        let sharpness = Double(edges) / Double(gray.count) * (1.0 - 0.9 * Double(clipped) / Double(gray.count))
        return (gray, sharpness)
    }

    private static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count)
    }

    /// Evidence-driven frame classifier: assigns a specific craft stage ONLY when real OCR or
    /// speech-timestamp evidence supports it; otherwise honestly labels as `"scene_highlight"` ("制作特写").
    public static func classifyFrameByEvidence(
        timestampS: Double,
        durationS: Double,
        ocrTexts: [String],
        speechSegments: [SpeechSegment],
        knownBeans: [BeanEntry] = [],
        alreadyHasScaleDose: Bool = false
    ) -> (stageKey: String, stageLabel: String, readings: VisualFieldReadings, evidenceNote: String) {
        let progress = durationS > 0 ? (timestampS / durationS) : 0.5

        // Run comprehensive OCR extraction gated by realistic timeline phase
        var readings = VisualFieldReadings()
        if progress <= 0.65 {
            let doseR = extractVisualFields(stage: "scale_dose", ocrTexts: ocrTexts, knownBeans: knownBeans)
            readings = readings.merged(overridingWith: doseR)
            let grinderR = extractVisualFields(stage: "grinding", ocrTexts: ocrTexts, knownBeans: knownBeans)
            readings = readings.merged(overridingWith: grinderR)
        }
        let pressureR = extractVisualFields(stage: "pressure_crema", ocrTexts: ocrTexts, knownBeans: knownBeans)
        readings = readings.merged(overridingWith: pressureR)
        if progress >= 0.45 {
            let yieldR = extractVisualFields(stage: "yield_timer", ocrTexts: ocrTexts, knownBeans: knownBeans)
            readings = readings.merged(overridingWith: yieldR)
        }

        // 1. Highest priority: direct OCR visual evidence on this exact frame
        if let weight = readings.beanWeightG {
            let wStr = String(format: "%.1fg", weight)
            if alreadyHasScaleDose {
                return ("dose_weigh", "复称出粉 (\(wStr))", readings, "OCR 电子秤读数 \(wStr)")
            }
            return ("scale_dose", "称重读数 (\(wStr))", readings, "OCR 电子秤读数 \(wStr)")
        }
        if readings.yieldG != nil || readings.extractionTimeS != nil {
            return ("yield_timer", "出杯液重与读秒", readings, "OCR 出杯/计时读数")
        }
        if readings.pressureBar != nil || readings.waterTempC != nil {
            return ("pressure_crema", "咖啡机萃取参数", readings, "OCR 压力/水温读数")
        }
        if readings.grindSetting != nil || readings.grinderModel != nil {
            return ("grinding", "磨豆机与刻度", readings, "OCR 磨豆机/刻度识别")
        }
        if let bean = readings.beanName, !bean.isEmpty {
            return ("bean_bag", "咖啡豆特写", readings, "OCR 豆袋识别：\(bean)")
        }

        // 2. Second priority: explicit spoken keyword or burned-in subtitle within ±3.5s
        let nearbySpeech = ChineseCoffeeAnalyzer.normalizeCoffeeText(
            speechSegments
                .filter { abs($0.timestampS - timestampS) <= 3.5 }
                .map(\.text)
                .joined(separator: "")
        ).lowercased()
        let frameSubtitle = ChineseCoffeeAnalyzer.normalizeCoffeeText(ocrTexts.joined(separator: " ")).lowercased()
        let combinedCue = nearbySpeech.isEmpty ? frameSubtitle : (frameSubtitle.isEmpty ? nearbySpeech : "\(nearbySpeech) \(frameSubtitle)")

        if !combinedCue.isEmpty {
            let speechRules: [(key: String, label: String, pattern: String)] = [
                ("wdt_distribute", "布粉针打散结块", "布粉针|打散|结块|结款|wdt|松粉"),
                ("leveler_flatten", "布粉器压平", "布粉器|压平|找平|整平|巴不平"),
                ("tamping", "压粉锤压粉", "压粉锤|压粪锤|鸭粉锤|压粉|压实|恒力|回弹"),
                ("dose_weigh", "接粉称重", "接粉|结粉|出粉量|出粉|粉量|粉重|复称|粉碗|接粉环|基本环"),
                ("grinding", "磨豆与出粉", "磨豆|研磨|刻度|刀盘|3828"),
                ("milk_frothing", "蒸汽打奶泡与拉花", "打奶泡|奶泡|拉花|蒸汽棒|蒸汽头|奶缸|打绵|牛奶液面"),
                ("pressure_crema", "咖啡机萃取与出液", "压力|油脂|虎斑|老鼠尾|出液|初夜|出夜|变压模式"),
                ("yield_timer", "出杯成品", "液重|出杯|成品|做好了|结束"),
                ("scale_dose", "称重豆量", "称豆|称重|豆量|咖啡豆|咸芝士"),
            ]
            for rule in speechRules {
                // Avoid mislabeling intro overview narration in the first 12% of a long video as active extraction/steaming
                if (rule.key == "pressure_crema" || rule.key == "milk_frothing"), durationS > 60, progress < 0.12 {
                    continue
                }
                if !regexMatches(pattern: rule.pattern, in: combinedCue).isEmpty {
                    return (rule.key, rule.label, readings, nearbySpeech.isEmpty ? "字幕动作锚点" : "语音锚点匹配")
                }
            }
        }

        // Check if this frame falls right inside active espresso pouring (8s..24s after "开始萃取/开始吹吹",
        // skipping the 0-7s pre-infusion & button-press delay so we capture the actual golden liquid stream).
        let recentExtractionCue = speechSegments
            .filter { timestampS >= $0.timestampS + 8.0 && timestampS <= $0.timestampS + 24.0 }
            .map(\.text)
            .joined(separator: "")
            .lowercased()
        if !recentExtractionCue.isEmpty,
           !(durationS > 60 && progress < 0.12),
           !regexMatches(pattern: "开始萃取|开始吹吹|萃取|吹吹", in: recentExtractionCue).isEmpty {
            return ("pressure_crema", "咖啡机萃取与出液", readings, "萃取进行中特写")
        }

        // 3. Honest fallback: no guessed craft stage — label cleanly as a visual highlight
        return ("scene_highlight", "制作特写", readings, "视觉场景变化优选")
    }

    private func extractKeyframesAndOCR(
        mediaURL: URL,
        durationS: Double?,
        speechSegments: [SpeechSegment],
        sourceDevice: String,
        extractFrames: Bool
    ) async -> ([KeyframeObservation], VisualFieldReadings, [String]) {
        let asset = AVURLAsset(url: mediaURL)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let duration = durationS, duration > 0, !videoTracks.isEmpty else {
            return ([], VisualFieldReadings(), [])
        }

        guard extractFrames else {
            return ([], VisualFieldReadings(), [])
        }

        let sessionSlug = deriveSessionSlug(from: mediaURL)
        let targetDir = keyframeBaseDirectory.appendingPathComponent(sessionSlug, isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        Self.applySandboxProtectionIfNeeded(at: keyframeBaseDirectory)
        Self.applySandboxProtectionIfNeeded(at: targetDir)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        // 1. Build dense probe timestamps (~every 2.5s, 6..24 probes) + inject key speech-anchor timestamps
        let probeCount = min(24, max(6, Int((duration / 2.5).rounded())))
        let startPad = min(0.8, duration * 0.03)
        let endPad = max(startPad + 0.1, duration - min(0.6, duration * 0.02))
        var probeTimes: [Double] = []
        if probeCount == 1 {
            probeTimes = [duration * 0.5]
        } else {
            let step = (endPad - startPad) / Double(probeCount - 1)
            for idx in 0..<probeCount {
                probeTimes.append(startPad + Double(idx) * step)
            }
        }
        // Also inject speech-anchor moments using a 3-second rolling window across segments
        // (Apple Speech often splits words like "布粉"+"针", "压"+"粪"+"锤", "开始"+"吹吹" across segments).
        let anchorSpecs: [(pattern: String, offsets: [Double])] = [
            ("咸芝士|咖啡豆", [0.5]),
            ("出粉|接粉|结粉|接粉环|基本环", [1.5]),
            ("布粉针|打散|结块|结款|松粉|wdt", [1.5]),
            ("布粉器|压平|找平|整平", [1.5]),
            ("压粉锤|压粪锤|鸭粉锤|压粉|压实", [1.5]),
            ("开始萃取|开始吹吹|萃取|吹吹", [10.0, 16.0, 22.0]),
            ("出液|初夜|出夜|油脂|虎斑", [0.0]),
            ("做好了|成品|结束", [-0.8]),
        ]
        var injectedStageHits = Set<String>()
        for i in 0..<speechSegments.count {
            let baseT = speechSegments[i].timestampS
            guard baseT > 0.3 && baseT < duration - 0.3 else { continue }
            var windowText = ""
            var j = i
            while j < speechSegments.count && (speechSegments[j].timestampS - baseT) <= 3.0 {
                windowText += speechSegments[j].text
                j += 1
            }
            for spec in anchorSpecs {
                guard !injectedStageHits.contains(spec.pattern) else { continue }
                if !Self.regexMatches(pattern: spec.pattern, in: windowText).isEmpty {
                    injectedStageHits.insert(spec.pattern)
                    for offset in spec.offsets {
                        let target = min(duration - 0.5, max(0.5, baseT + offset))
                        if probeTimes.allSatisfy({ abs($0 - target) >= 2.0 }) {
                            probeTimes.append(target)
                        }
                    }
                }
            }
        }
        probeTimes.sort()

        // 2. Decode probes, run Vision OCR on every probe (so brief bean-bag / scale shots are never missed),
        //    and measure frame-to-frame visual scene changes + sharpness.
        var probes: [SceneProbe] = []
        var globalReadings = VisualFieldReadings()
        for seconds in probeTimes {
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: targetTime) {
                let actual = CMTimeGetSeconds(result.actualTime)
                if actual.isFinite {
                    let (gray, sharpness) = Self.grayscaleSignatureAndSharpness(result.image)
                    let diff = probes.last.map { Self.meanAbsDiff($0.gray64, gray) } ?? 100.0
                    let ocrTexts = Self.recognizeText(in: result.image)
                    let classified = Self.classifyFrameByEvidence(
                        timestampS: actual,
                        durationS: duration,
                        ocrTexts: ocrTexts,
                        speechSegments: speechSegments,
                        knownBeans: knownBeans
                    )
                    globalReadings = globalReadings.merged(overridingWith: classified.readings)
                    probes.append(
                        SceneProbe(
                            image: result.image,
                            timestampS: actual,
                            gray64: gray,
                            sharpnessScore: sharpness,
                            transitionDiff: diff,
                            ocrTexts: ocrTexts,
                            readings: classified.readings,
                            stageKey: classified.stageKey
                        )
                    )
                }
            }
        }

        guard !probes.isEmpty else {
            return ([], VisualFieldReadings(), [])
        }

        // 3. Segment probes into distinct visual scenes (content-driven, never fixed percentages)
        var scenes: [[SceneProbe]] = []
        let maxSceneSpan = max(10.0, duration / 7.0)
        for probe in probes {
            if let lastScene = scenes.last, let firstInScene = lastScene.first {
                let elapsed = probe.timestampS - firstInScene.timestampS
                let isMajorCut = probe.transitionDiff >= 24.0
                let isGradualChange = elapsed >= maxSceneSpan && probe.transitionDiff >= 12.0
                if isMajorCut || isGradualChange {
                    scenes.append([probe])
                } else {
                    scenes[scenes.count - 1].append(probe)
                }
            } else {
                scenes.append([probe])
            }
        }

        let actionStageBonusKeys: Set<String> = [
            "dose_weigh", "grinding", "wdt_distribute", "leveler_flatten", "tamping", "pressure_crema", "milk_frothing", "yield_timer",
        ]

        // Inside each visual scene, prefer frames that BOTH are sharp AND captured a real brewing action or OCR field
        func probeRank(_ p: SceneProbe) -> Double {
            let fieldCount = p.readings.asDisplayDictionary.count
            let hasBeanOrWeight = (p.readings.beanName != nil || p.readings.beanWeightG != nil || p.readings.yieldG != nil) ? 8.0 : 0.0
            let hasTextBonus = p.ocrTexts.isEmpty ? 0.0 : 2.0
            let actionBonus = actionStageBonusKeys.contains(p.stageKey) ? 28.0 : (p.stageKey != "scene_highlight" ? 12.0 : 0.0)
            return p.sharpnessScore + Double(fieldCount * 10) + hasBeanOrWeight + hasTextBonus + actionBonus
        }

        var winners: [SceneProbe] = scenes.compactMap { group in
            group.max(by: { probeRank($0) < probeRank($1) })
        }

        // Also ensure every distinct spoken action stage (dosing, WDT, tamping, extraction/pouring, milk frothing)
        // gets its own dedicated winner even if two actions happened in the same tripod camera angle.
        let priorityActionOrder = ["dose_weigh", "wdt_distribute", "leveler_flatten", "tamping", "pressure_crema", "milk_frothing", "yield_timer"]
        for actionKey in priorityActionOrder {
            if !winners.contains(where: { $0.stageKey == actionKey }),
               let bestActionProbe = probes.filter({ $0.stageKey == actionKey }).max(by: { probeRank($0) < probeRank($1) }) {
                if winners.allSatisfy({ abs($0.timestampS - bestActionProbe.timestampS) >= 2.0 }) {
                    winners.append(bestActionProbe)
                }
            }
        }
        winners.sort { $0.timestampS < $1.timestampS }

        // If tripod shot was very static (< 3 scenes), split evenly into 3..5 best highlights
        if winners.count < 3 && probes.count >= 3 {
            let targetBuckets = min(5, max(3, Int((duration / 12.0).rounded())))
            let bucketSize = max(1, probes.count / targetBuckets)
            winners = stride(from: 0, to: probes.count, by: bucketSize).compactMap { start in
                let slice = probes[start..<min(probes.count, start + bucketSize)]
                return slice.max(by: { probeRank($0) < probeRank($1) })
            }
        }

        // Cap at 8 distinct scenes, ALWAYS protecting:
        // 1) early-half scene (<45%) so tripod intros don't get dropped,
        // 2) any title/brand frame carrying an explicit coffee machine brand/model in OCR,
        // 3) final scene (finished cup),
        // 4) distinct brewing action stages (dosing/WDT/tamp/extraction/steaming),
        // 5) OCR-evidence scenes
        if winners.count > 8 {
            var protectedIndices = Set<Int>()
            protectedIndices.insert(winners.count - 1)
            let brandOCRPattern = #"百胜图|barsetto|2sap|bae02s|小米|米家|xiaomi|mijia|格米莱|格米萊|gemilai|crm3605|佩罗奇|佩洛奇|peloqi|马克西姆|mokkom|塞纳|德龙|德龍|delonghi|de'longhi|dedica|ec685"#
            if let brandIdx = winners.firstIndex(where: { !Self.regexMatches(pattern: brandOCRPattern, in: $0.ocrTexts.joined(separator: " ")).isEmpty }) {
                protectedIndices.insert(brandIdx)
            }
            if let earlyIdx = winners.enumerated()
                .filter({ $0.element.timestampS >= 3.0 && ($0.element.timestampS / duration) < 0.45 })
                .max(by: { probeRank($0.element) < probeRank($1.element) })?.offset {
                protectedIndices.insert(earlyIdx)
            }
            for actionKey in priorityActionOrder {
                if let idx = winners.firstIndex(where: { $0.stageKey == actionKey }) {
                    if protectedIndices.count < 7 {
                        protectedIndices.insert(idx)
                    }
                }
            }
            for (idx, w) in winners.enumerated() where !w.readings.asDisplayDictionary.isEmpty {
                if protectedIndices.count < 7 {
                    protectedIndices.insert(idx)
                }
            }
            let remainingSlots = max(0, 8 - protectedIndices.count)
            let others = winners.enumerated()
                .filter { !protectedIndices.contains($0.offset) }
                .sorted { lhs, rhs in
                    let lScore = lhs.element.transitionDiff * 0.6 + probeRank(lhs.element)
                    let rScore = rhs.element.transitionDiff * 0.6 + probeRank(rhs.element)
                    return lScore > rScore
                }
            for item in others.prefix(remainingSlots) {
                protectedIndices.insert(item.offset)
            }
            winners = winners.enumerated().filter { protectedIndices.contains($0.offset) }.map(\.element)
        }

        // 4. Write selected scene JPEGs, classify visual coffee scenes, and assemble evidence-driven observations
        var observations: [KeyframeObservation] = []
        var mergedReadings = globalReadings
        var hasScaleDoseSoFar = false
        var sceneTagCounts: [String: Int] = [:]

        for (idx, winner) in winners.enumerated() {
            let classified = Self.classifyFrameByEvidence(
                timestampS: winner.timestampS,
                durationS: duration,
                ocrTexts: winner.ocrTexts,
                speechSegments: speechSegments,
                knownBeans: knownBeans,
                alreadyHasScaleDose: hasScaleDoseSoFar
            )
            if classified.readings.beanWeightG != nil {
                hasScaleDoseSoFar = true
            }
            mergedReadings = mergedReadings.merged(overridingWith: classified.readings)

            for tag in Self.classifyVisualSceneTags(in: winner.image) {
                sceneTagCounts[tag, default: 0] += 1
            }

            let actualPct = max(0, min(100, Int((100.0 * winner.timestampS / duration).rounded())))
            let fileName = String(format: "scene_%02d_%02dpct_%@.jpg", idx + 1, actualPct, classified.stageKey)
            let outputURL = targetDir.appendingPathComponent(fileName)
            let saved = Self.writeJPEG(winner.image, to: outputURL, quality: 0.85)

            var desc = "\(sourceDevice) 动态场景抽帧（\(classified.evidenceNote), t=\(String(format: "%.1f", winner.timestampS))s, 清晰度 \(String(format: "%.1f", winner.sharpnessScore))）"
            if !winner.ocrTexts.isEmpty {
                let preview = winner.ocrTexts.prefix(4).joined(separator: " / ").prefix(120)
                desc += "；OCR：\(preview)"
            }

            observations.append(
                KeyframeObservation(
                    stageKey: classified.stageKey,
                    stage: classified.stageLabel,
                    percentage: actualPct,
                    timestampS: (winner.timestampS * 1000).rounded() / 1000,
                    detectedFields: classified.readings.asDisplayDictionary,
                    visualDescription: desc,
                    ocrTexts: winner.ocrTexts,
                    sharpnessScore: (winner.sharpnessScore * 1000).rounded() / 1000,
                    imagePath: saved ? outputURL.path : nil,
                    extracted: saved
                )
            )
        }

        // Keep tags that appeared with strong coffee semantics or repeatedly (>= 2 keyframes)
        let directCoffeeTags: Set<String> = ["coffee", "espresso", "latte", "cappuccino", "coffee_maker", "espresso_maker"]
        let aggregatedSceneTags = sceneTagCounts
            .filter { directCoffeeTags.contains($0.key) || $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .map(\.key)

        return (observations, mergedReadings, aggregatedSceneTags)
    }

    // MARK: - Stage Window & Candidate Selection

    private func computeStageTimeWindows(
        durationS: Double,
        speechSegments: [SpeechSegment]
    ) -> [String: StageWindow] {
        struct AnchorCandidate {
            let inNaturalWindow: Bool
            let hasKeywordMatch: Bool
            let specificity: Int
            let timestamp: Double
            let isStopOnly: Bool

            func isBetter(than other: AnchorCandidate) -> Bool {
                if inNaturalWindow != other.inNaturalWindow { return inNaturalWindow }
                if hasKeywordMatch != other.hasKeywordMatch { return hasKeywordMatch }
                if specificity != other.specificity { return specificity > other.specificity }
                return timestamp > other.timestamp
            }
        }

        let specByKey = Dictionary(uniqueKeysWithValues: Self.stageSpecs.map { ($0.key, $0) })
        var stageCandidates: [String: [AnchorCandidate]] = [:]

        for i in speechSegments.indices {
            let seg = speechSegments[i]
            let ts = seg.timestampS
            guard ts > 0 && ts < durationS else { continue }
            let first = seg.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            var combined = first
            let lookaheadEnd = min(speechSegments.count, i + 4)
            if i + 1 < lookaheadEnd {
                for j in (i + 1)..<lookaheadEnd {
                    let nextSeg = speechSegments[j]
                    let dt = nextSeg.timestampS - ts
                    if dt < 0 || dt > 1.0 { break }
                    combined += nextSeg.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let firstUTF16Count = first.utf16.count
            for (stageKey, pattern) in Self.stageKeywordPatterns {
                let stopMatches = Self.regexMatches(pattern: Self.stopPattern, in: combined)
                    .filter { $0.range.location < firstUTF16Count }
                let isStop = (stageKey == "yield_timer") && !stopMatches.isEmpty
                let kwMatches = Self.regexMatches(pattern: pattern, in: combined)
                    .filter { $0.range.location < firstUTF16Count }
                if kwMatches.isEmpty && !isStop { continue }

                let specificity = kwMatches.map { $0.range.length }.max() ?? 0
                let spec = specByKey[stageKey]
                let lo = (spec?.windowLow ?? 0.0) * durationS - 4.0
                let hi = (spec?.windowHigh ?? 1.0) * durationS + 10.0
                let inWindow = ts >= lo && ts <= hi

                stageCandidates[stageKey, default: []].append(
                    AnchorCandidate(
                        inNaturalWindow: inWindow,
                        hasKeywordMatch: !kwMatches.isEmpty,
                        specificity: specificity,
                        timestamp: ts,
                        isStopOnly: isStop && kwMatches.isEmpty
                    )
                )
            }
        }

        var anchors: [String: AnchorCandidate] = [:]
        var usedTimestamps: [Double] = []
        for spec in Self.stageSpecs {
            let sorted = (stageCandidates[spec.key] ?? []).sorted { $0.isBetter(than: $1) }
            if let pick = sorted.first(where: { cand in usedTimestamps.allSatisfy { abs(cand.timestamp - $0) >= 8.0 } }) {
                anchors[spec.key] = pick
                usedTimestamps.append(pick.timestamp)
            } else if let pick = sorted.first(where: { cand in usedTimestamps.allSatisfy { abs(cand.timestamp - $0) >= 4.0 } }) {
                anchors[spec.key] = pick
                usedTimestamps.append(pick.timestamp)
            }
        }

        var windows: [String: StageWindow] = [:]
        var prevEnd = -10.0
        for spec in Self.stageSpecs {
            var start = spec.windowLow * durationS
            var end = spec.windowHigh * durationS
            var center = spec.fraction * durationS
            var anchored = false

            if let anchor = anchors[spec.key] {
                if anchor.isStopOnly {
                    start = max(0.0, anchor.timestamp - 3.0)
                    end = max(0.0, anchor.timestamp - 0.4)
                    if end <= start { end = anchor.timestamp }
                    center = (start + end) / 2.0
                } else {
                    start = max(0.0, anchor.timestamp - 1.5)
                    end = min(durationS, anchor.timestamp + 1.5)
                    center = anchor.timestamp
                }
                anchored = true
            }

            if start <= prevEnd + 1.0 && end > prevEnd + 2.0 {
                start = min(end - 0.5, prevEnd + 1.5)
                if center < start {
                    center = (start + end) / 2.0
                }
            }
            prevEnd = max(prevEnd, anchored ? end : center)
            windows[spec.key] = StageWindow(start: start, end: end, center: center, anchored: anchored)
        }
        return windows
    }

    private func candidateTimes(window: StageWindow, durationS: Double) -> [Double] {
        let cap = max(0.0, durationS - min(0.02, durationS / 10.0))
        let raw = [
            window.center,
            window.start,
            window.end,
            (window.start + window.end) / 2.0,
            window.start + (window.end - window.start) / 3.0,
        ].map { min(max(0.0, $0), cap) }

        var unique: [Double] = []
        for t in raw {
            if !unique.contains(where: { abs($0 - t) < 0.01 }) {
                unique.append(t)
            }
            if unique.count == 4 { break }
        }
        return unique
    }

    private func selectBestCandidate(
        stage: String,
        candidates: [FrameCandidate],
        center: Double
    ) -> FrameCandidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            let sL = candidateScore(stage: stage, candidate: lhs, center: center)
            let sR = candidateScore(stage: stage, candidate: rhs, center: center)
            if sL.0 != sR.0 { return sL.0 < sR.0 }
            return sL.1 < sR.1
        }
    }

    private func candidateScore(
        stage: String,
        candidate: FrameCandidate,
        center: Double
    ) -> (Double, Double) {
        let normalized = candidate.ocrTexts.map { $0.precomposedStringWithCompatibilityMapping }.joined(separator: " ")
        let numbers = Self.regexMatches(pattern: Self.numberPattern, in: normalized).compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: normalized) else { return nil }
            return Double(normalized[range])
        }

        let range: (Double, Double)
        let contextPattern: String
        switch stage {
        case "scale_dose", "dose_weigh":
            range = (10, 26)
            contextPattern = #"咖啡豆|豆量|出粉|接粉|粉量|粉重|烘焙度|风味|养豆期|赏味期|浅烘|中烘|深烘|水洗|日晒|\bSOE\b|\bgrams?\b|\bg\b|克|\d+\.\d"#
        case "grinding", "grinder_dial":
            range = (0, 99)
            contextPattern = #"刻度|刀盘|grind|dial|roasters|磨豆|出粉|低因|咸芝士|\bSOE\b"#
        case "wdt_distribute", "leveler_flatten", "tamping":
            range = (10, 26)
            contextPattern = #"布粉|压粉|粉碗|手柄|58mm|\bg\b"#
        case "pressure_crema":
            range = (5, 15)
            contextPattern = #"压力|\bbar\b|°C"#
        default:
            range = (15, 80)
            contextPattern = #"液重|出液|\b0{1,2}:|\bs\b|秒|\d+\.\d"#
        }

        let plausible = numbers.contains { n in
            (n >= range.0 && n <= range.1) || (stage == "pressure_crema" && n >= 85 && n <= 99)
        }
        let hasContext = !Self.regexMatches(pattern: contextPattern, in: normalized).isEmpty
        let ocrFields = Self.extractVisualFields(stage: stage, ocrTexts: candidate.ocrTexts, knownBeans: knownBeans)
        let fieldCount = ocrFields.asDisplayDictionary.count
        let contextBonus = (stage == "grinder_dial" && hasContext) ? 8.0 : (hasContext ? 1.0 : 0.0)
        let relevance = Double(6 * fieldCount) + (plausible ? 2.0 : 0.0) + contextBonus
        return (candidate.sharpnessScore + relevance, -abs(candidate.timestampS - center))
    }

    // MARK: - Vision OCR & Sharpness Scoring

    public static func sharpnessQuality(_ image: CGImage) -> Double {
        let side = 64
        var gray = [UInt8](repeating: 0, count: side * side)
        gray.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(
                data: pixels.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: 0
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var edges = 0
        var clipped = 0
        for i in 0..<gray.count {
            let pixel = Int(gray[i])
            if pixel < 20 || pixel > 235 { clipped += 1 }
            if i % side > 0 { edges += abs(pixel - Int(gray[i - 1])) }
            if i >= side { edges += abs(pixel - Int(gray[i - side])) }
        }
        return Double(edges) / Double(gray.count) * (1.0 - 0.9 * Double(clipped) / Double(gray.count))
    }

    /// Validates `CGImage` bounds and normalizes working resolution before Apple Vision requests:
    /// - Rejects zero, negative, or decompression-bomb dimensions (`>16384` px or `>100MP`).
    /// - Upscales low-res social clips (`<900` px) up to 2x within a strict `2,073,600`-pixel budget.
    /// - Downsamples oversized photos (`>2560` px or `>4.1MP`) so multi-photo Vision OCR cannot exhaust RAM.
    private static func prepareVisionImage(_ image: CGImage, upscaleLowRes: Bool) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, w <= maxInputImageDimension, h <= maxInputImageDimension else {
            return nil
        }
        let pixels = Int64(w) * Int64(h)
        guard pixels > 0 && pixels <= 100_000_000 else {
            return nil
        }

        let maxDim = max(w, h)
        var targetScale: Double = 1.0
        if upscaleLowRes && maxDim < 900 {
            let dimScale = min(2.0, 1080.0 / Double(maxDim))
            let pixelCapScale = sqrt(Double(maxUpscaledPixels) / Double(pixels))
            targetScale = min(dimScale, pixelCapScale)
        } else if maxDim > maxOCRWorkingDimension || pixels > 4_096_000 {
            let dimScale = Double(maxOCRWorkingDimension) / Double(maxDim)
            let pixelCapScale = sqrt(4_096_000.0 / Double(pixels))
            targetScale = min(dimScale, pixelCapScale)
        }

        guard abs(targetScale - 1.0) > 0.02 else {
            return image
        }

        let newW = max(1, min(maxOCRWorkingDimension, Int((Double(w) * targetScale).rounded())))
        let newH = max(1, min(maxOCRWorkingDimension, Int((Double(h) * targetScale).rounded())))
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return maxDim <= maxOCRWorkingDimension ? image : nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? (maxDim <= maxOCRWorkingDimension ? image : nil)
    }

    public static func recognizeText(in image: CGImage) -> [String] {
        // Upscale low-resolution / vertical social videos (e.g. 360x640, 640x360) before Vision OCR
        // while bounding oversized photos to prevent memory exhaustion.
        guard let targetImage = prepareVisionImage(image, upscaleLowRes: true) else {
            return []
        }

        return autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.012
            if let supported = try? request.supportedRecognitionLanguages() {
                let preferred = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
                if !preferred.isEmpty {
                    request.recognitionLanguages = preferred
                }
            }
            do {
                try VNImageRequestHandler(cgImage: targetImage, options: [:]).perform([request])
                return (request.results ?? [])
                    .prefix(120)
                    .compactMap { obs in
                        guard let raw = obs.topCandidates(1).first?.string else { return nil }
                        return String(raw.prefix(500))
                    }
            } catch {
                return []
            }
        }
    }

    private static let coffeeVisualLabelWhitelist: Set<String> = [
        "coffee", "espresso", "latte", "cappuccino", "coffee_maker", "espresso_maker",
        "cup", "mug", "drinking_glass", "drink", "beverage", "kettle", "teapot",
        "tableware", "utensil", "appliance", "machine",
    ]

    /// Runs on-device Apple Vision image classification (`VNClassifyImageRequest`)
    /// to detect coffee/beverage/brewing visual context for silent/ASMR videos.
    public static func classifyVisualSceneTags(in image: CGImage) -> [String] {
        guard let targetImage = prepareVisionImage(image, upscaleLowRes: false) else {
            return []
        }
        return autoreleasepool {
            let request = VNClassifyImageRequest()
            do {
                try VNImageRequestHandler(cgImage: targetImage, options: [:]).perform([request])
                return (request.results ?? []).compactMap { obs in
                    let id = obs.identifier.lowercased()
                    guard coffeeVisualLabelWhitelist.contains(id) else { return nil }
                    let threshold: Float = (id == "coffee" || id == "espresso" || id == "latte" || id == "cappuccino" || id == "coffee_maker") ? 0.12 : 0.18
                    return obs.confidence >= threshold ? id : nil
                }
            } catch {
                return []
            }
        }
    }

    public static func extractVisualFields(
        stage: String,
        ocrTexts: [String],
        knownBeans: [BeanEntry] = []
    ) -> VisualFieldReadings {
        let lines = ocrTexts
            .prefix(120)
            .map { String($0.prefix(500)).precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = String(lines.joined(separator: " ").prefix(12_000))
        var out = VisualFieldReadings()

        func parseNumericReading(lo: Double, hi: Double, suffixPattern: String, decimalOnly: Bool = false) -> Double? {
            let pattern = numberPattern + #"\s*(?:"# + suffixPattern + ")"
            for match in regexMatches(pattern: pattern, in: text) {
                guard let fullRange = Range(match.range, in: text),
                      let numRange = Range(match.range(at: 1), in: text),
                      let value = Double(text[numRange])
                else { continue }
                let prefixStart = text.index(fullRange.lowerBound, offsetBy: -4, limitedBy: text.startIndex) ?? text.startIndex
                let prefix = String(text[prefixStart..<fullRange.lowerBound])
                if !regexMatches(pattern: #"\d\s*[-~～—・•]\s*$"#, in: prefix).isEmpty {
                    continue
                }
                if value >= lo && value <= hi {
                    return value
                }
            }
            if decimalOnly {
                var decimals = Set<Double>()
                for line in lines {
                    // Match both standalone "18.0" and LED scale displays like "00:00  18.2", "g 18.0", "18.0."
                    let stripped = line.replacingOccurrences(of: #"0?\d:\d{2}"#, with: " ", options: .regularExpression)
                    for m in regexMatches(pattern: #"(?<![0-9.])(\d{1,2}\.\d{1,2})(?![0-9.])"#, in: stripped) {
                        if let r = Range(m.range(at: 1), in: stripped),
                           let val = Double(stripped[r]),
                           val >= lo && val <= hi {
                            decimals.insert(val)
                        }
                    }
                }
                if decimals.count == 1 {
                    return decimals.first
                }
            }
            return nil
        }

        // Digital coffee scales can appear anywhere in the first 65% of the video (bean weighing OR grounds weighing).
        if ["scale_dose", "grinding", "dose_weigh", "wdt_distribute", "leveler_flatten"].contains(stage) {
            out.beanWeightG = parseNumericReading(lo: 10, hi: 26, suffixPattern: #"g(?![a-z0-9])|克"#, decimalOnly: true)
        }

        // Bean name matching across stages
        let normalizedOCR = replacingRegex(
            pattern: #"[咸感][^a-zA-Z0-9\s]{0,3}低因(?:\s*5o[ceg])?"#,
            in: text,
            with: "咸芝士低因 SOE"
        )
        let lowerOCR = normalizedOCR.lowercased()
        var bestBeanMatch: (length: Int, name: String)?
        for bean in knownBeans {
            let aliases = [bean.fullName] + bean.shortAliases
            for alias in aliases where !alias.isEmpty {
                if lowerOCR.contains(alias.lowercased()) {
                    if bestBeanMatch.map({ alias.count > $0.length }) ?? true {
                        bestBeanMatch = (alias.count, bean.fullName)
                    }
                }
            }
        }
        if let best = bestBeanMatch {
            out.beanName = best.name
        } else if let originMatch = regexMatches(pattern: beanOriginPattern, in: normalizedOCR).first,
                  let range = Range(originMatch.range, in: normalizedOCR) {
            out.beanName = String(normalizedOCR[range])
        }

        if stage == "grinder_dial" || stage == "grinding" {
            let escapedModels = grinderModels.map {
                NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: #"\ "#, with: #"\s+"#)
            }.joined(separator: "|")
            let brandPattern = #"(?<![a-z0-9])(?:"# + escapedModels + #")(?![a-z0-9])"#
            if let modelMatch = regexMatches(pattern: brandPattern, in: text).first,
               let range = Range(modelMatch.range, in: text) {
                let raw = String(text[range]).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                out.grinderModel = grinderModels.first { $0.lowercased() == raw } ?? String(text[range])
            }
            let dialPattern = #"(?:刻度|setting|dial)\s{0,6}(?:[:#]\s{0,6})?"# + numberPattern
            if let dialMatch = regexMatches(pattern: dialPattern, in: text).first,
               let numRange = Range(dialMatch.range(at: 1), in: text) {
                out.grindSetting = "刻度 \(text[numRange])"
            } else if out.beanWeightG == nil && out.grinderModel != nil {
                // Only treat a standalone integer as a grinder dial if a grinder brand/model is visible on the same frame.
                let standalone = Set(lines.filter { !regexMatches(pattern: #"^\d{1,2}$"#, in: $0).isEmpty })
                if standalone.count == 1, let only = standalone.first {
                    out.grindSetting = "刻度 \(only)"
                }
            }
        } else if stage == "pressure_crema" {
            out.pressureBar = parseNumericReading(lo: 8, hi: 12, suffixPattern: #"bar\b|巴"#)
            out.waterTempC = parseNumericReading(lo: 88, hi: 96, suffixPattern: #"°\s*[cC]|℃|摄氏度|で"#)
        } else if stage == "yield_timer" {
            out.yieldG = parseNumericReading(lo: 25, hi: 65, suffixPattern: #"g(?![a-z0-9])|克"#, decimalOnly: true)
            out.extractionTimeS = parseNumericReading(lo: 18, hi: 45, suffixPattern: #"s(?:ec(?:onds?)?)?\b|秒"#)
            for match in regexMatches(pattern: #"(?<![\d:])0{1,2}\s*:\s*([0-5]\d)(?![\d:])"#, in: text) {
                if let secRange = Range(match.range(at: 1), in: text),
                   let sec = Int(text[secRange]),
                   (18...45).contains(sec) {
                    out.extractionTimeS = Double(sec)
                    break
                }
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        let ok = CGImageDestinationFinalize(destination)
        if ok {
            applySandboxProtectionIfNeeded(at: url)
        }
        return ok
    }

    internal func deriveSessionSlug(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let sanitized = base
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        let capped = String(sanitized.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if capped.isEmpty || capped == "." || capped == ".." {
            return "session_\(UUID().uuidString.prefix(8))"
        }
        return capped
    }

    private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range)
    }

    private static func replacingRegex(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Selects the top `maxClips` most visually dynamic coffee-brewing moments for 2.5s LIVE clips,
    /// prioritizing real action stages (dosing/grinding -> WDT/leveling/tamping -> espresso extraction/pouring -> final cup)
    /// and avoiding static 0% intro frames whenever real action frames exist.
    public static func selectLiveClipKeyframes(
        from keyframes: [KeyframeObservation],
        maxClips: Int = 4
    ) -> [KeyframeObservation] {
        let cappedMax = min(maxClips, 8)
        let validKeyframes = keyframes.filter { $0.timestampS.isFinite && $0.timestampS >= 0 }
        guard !validKeyframes.isEmpty, cappedMax > 0 else { return [] }
        if validKeyframes.count <= cappedMax {
            return validKeyframes.sorted { $0.timestampS < $1.timestampS }
        }
        let safeSharpness: (KeyframeObservation) -> Double = { kf in
            kf.sharpnessScore.isFinite ? kf.sharpnessScore : 0.0
        }

        // Priority buckets representing the most engaging dynamic coffee actions
        let actionBuckets: [[String]] = [
            ["dose_weigh", "grinding"],
            ["wdt_distribute", "leveler_flatten", "tamping"],
            ["pressure_crema"],
            ["milk_frothing", "yield_timer"],
        ]

        var picked: [KeyframeObservation] = []
        var pickedIDs = Set<String>()

        for bucket in actionBuckets {
            guard picked.count < cappedMax else { break }
            let candidates = validKeyframes.filter { bucket.contains($0.stageKey) && !pickedIDs.contains($0.id) }
            if let best = candidates.max(by: { safeSharpness($0) < safeSharpness($1) }) {
                picked.append(best)
                pickedIDs.insert(best.id)
            }
        }

        // Second pass: grab additional DISTINCT action stages that are well-spaced (>=10% apart)
        let allActionKeys: Set<String> = ["dose_weigh", "grinding", "wdt_distribute", "leveler_flatten", "tamping", "pressure_crema", "milk_frothing", "yield_timer"]
        var pickedStages = Set(picked.map(\.stageKey))
        for kf in validKeyframes where picked.count < cappedMax {
            if allActionKeys.contains(kf.stageKey),
               !pickedIDs.contains(kf.id),
               !pickedStages.contains(kf.stageKey),
               picked.allSatisfy({ abs($0.percentage - kf.percentage) >= 10 }) {
                picked.append(kf)
                pickedIDs.insert(kf.id)
                pickedStages.insert(kf.stageKey)
            }
        }

        // Third pass: ensure timeline diversity — include a late/finished-cup frame (>=75%) if none picked yet
        if picked.count < cappedMax,
           !picked.contains(where: { $0.percentage >= 75 }),
           let lateFrame = validKeyframes
               .filter({ !pickedIDs.contains($0.id) && $0.percentage >= 75 })
               .max(by: { safeSharpness($0) < safeSharpness($1) }) {
            picked.append(lateFrame)
            pickedIDs.insert(lateFrame.id)
        }

        // Fourth pass: fill remaining slots with well-spaced (>=12% apart) sharp non-intro frames
        let nonIntro = validKeyframes.filter { !pickedIDs.contains($0.id) && $0.timestampS >= 3.0 }
        for kf in nonIntro.sorted(by: { safeSharpness($0) > safeSharpness($1) }) where picked.count < cappedMax {
            if picked.allSatisfy({ abs($0.percentage - kf.percentage) >= 12 }) {
                picked.append(kf)
                pickedIDs.insert(kf.id)
            }
        }
        // Final fallback if still under cappedMax (e.g. very short clips or closely clustered scenes)
        for kf in nonIntro.sorted(by: { safeSharpness($0) > safeSharpness($1) }) where picked.count < cappedMax && !pickedIDs.contains(kf.id) {
            picked.append(kf)
            pickedIDs.insert(kf.id)
        }
        for kf in validKeyframes where picked.count < cappedMax && !pickedIDs.contains(kf.id) {
            picked.append(kf)
            pickedIDs.insert(kf.id)
        }

        return picked.sorted { $0.timestampS < $1.timestampS }
    }

    /// Exports up to `maxClips` 2.5-second close-up highlight video clips around key brewing moments.
    /// Uses `AVAssetExportPresetPassthrough` first (lossless, fast, 4K HDR/Dolby Vision safe)
    /// and automatically falls back to `AVAssetExportPreset1920x1080` / `AVAssetExportPresetHighestQuality`.
    public static func exportDynamicCloseUpClips(
        videoURL: URL,
        keyframes: [KeyframeObservation],
        outputDirectory: URL? = nil,
        maxClips: Int = 4,
        clipDurationS: Double = 2.5
    ) async -> [URL] {
        guard maxClips > 0,
              videoURL.isFileURL,
              videoExtensions.contains(videoURL.pathExtension.lowercased()),
              let safeVideoPath = SandboxPathResolver.resolveLocalFilePath(videoURL.path)
        else {
            return []
        }
        let validKeyframes = keyframes.filter { $0.timestampS.isFinite && $0.timestampS >= 0 }
        guard !validKeyframes.isEmpty else {
            return []
        }
        let rawTargetDir = outputDirectory ?? FileManager.default.temporaryDirectory
        guard let targetDir = SandboxPathResolver.validateWritableDirectory(rawTargetDir) else {
            return []
        }

        let effectiveMaxClips = min(maxClips, 8)
        let requestedDurationS = (clipDurationS.isFinite && clipDurationS >= 0.8) ? min(clipDurationS, 15.0) : 2.5

        let asset = AVURLAsset(url: URL(fileURLWithPath: safeVideoPath))
        guard let dur = try? await asset.load(.duration) else { return [] }
        let totalSec = CMTimeGetSeconds(dur)
        guard totalSec.isFinite && totalSec > 1.0 else { return [] }

        let chosenKeyframes: [KeyframeObservation]
        if validKeyframes.count <= effectiveMaxClips {
            chosenKeyframes = validKeyframes
        } else if effectiveMaxClips == 1 {
            chosenKeyframes = [validKeyframes[validKeyframes.count / 2]]
        } else {
            let count = effectiveMaxClips
            var indices: [Int] = []
            for i in 0..<count {
                let idx = Int(round(Double(i) * Double(validKeyframes.count - 1) / Double(count - 1)))
                if !indices.contains(idx) {
                    indices.append(idx)
                }
            }
            chosenKeyframes = indices.map { validKeyframes[$0] }
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        applySandboxProtectionIfNeeded(at: targetDir)

        let presetAttempts: [(preset: String, fileType: AVFileType, ext: String)] = [
            (AVAssetExportPresetPassthrough, .mov, "mov"),
            (AVAssetExportPreset1920x1080, .mp4, "mp4"),
            (AVAssetExportPresetHighestQuality, .mov, "mov"),
        ]

        var exportedURLs: [URL] = []
        for (idx, kf) in chosenKeyframes.enumerated() {
            let safeDur = min(requestedDurationS, max(0.8, totalSec))
            let idealStart = kf.timestampS - (safeDur * 0.4)
            let clampedStart = min(max(0.0, idealStart), max(0.0, totalSec - safeDur))
            let length = min(safeDur, max(0.8, totalSec - clampedStart))
            guard clampedStart.isFinite, length.isFinite, length >= 0.8 else { continue }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: clampedStart, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )

            for attempt in presetAttempts {
                guard let exporter = AVAssetExportSession(asset: asset, presetName: attempt.preset) else {
                    continue
                }
                let outURL = targetDir.appendingPathComponent(
                    "xhs_closeup_\(idx)_\(UUID().uuidString.prefix(6)).\(attempt.ext)"
                )
                try? FileManager.default.removeItem(at: outURL)

                exporter.outputURL = outURL
                exporter.outputFileType = attempt.fileType
                exporter.timeRange = timeRange
                exporter.shouldOptimizeForNetworkUse = true

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    exporter.exportAsynchronously {
                        continuation.resume()
                    }
                }

                if exporter.status == .completed,
                   FileManager.default.fileExists(atPath: outURL.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
                   let size = attrs[.size] as? NSNumber,
                   size.intValue > 1024 {
                    applySandboxProtectionIfNeeded(at: outURL)
                    exportedURLs.append(outURL)
                    break
                } else {
                    try? FileManager.default.removeItem(at: outURL)
                }
            }
        }
        return exportedURLs
    }
}

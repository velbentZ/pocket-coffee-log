import CoreGraphics
import Foundation
import XCTest
@testable import PocketCoffeeCore

final class SecurityAuditTests: XCTestCase {

    func testSandboxPathResolverBlocksTraversalSymlinksDirectoriesAndNonMedia() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pc-sec-\(UUID().uuidString)", isDirectory: true)
        let docsDir = root.appendingPathComponent("Documents", isDirectory: true)
        let cachesDir = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let appSupportDir = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let outsideDir = fm.temporaryDirectory.appendingPathComponent("pc-outside-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outsideDir)
        }

        // 1. Valid media file inside sandbox resolves cleanly
        let validJPG = docsDir.appendingPathComponent("frame_01.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: validJPG)
        let resolvedValid = SandboxPathResolver.resolveLocalFilePath(
            validJPG.path,
            documentsDirectory: docsDir,
            cachesDirectory: cachesDir,
            applicationSupportDirectory: appSupportDir
        )
        XCTAssertNotNil(resolvedValid)

        // 2. Non-media config/JSON file inside sandbox is rejected
        let secretJSON = docsDir.appendingPathComponent("coffee_records.json")
        try Data("{}".utf8).write(to: secretJSON)
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                secretJSON.path,
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )

        // 3. Directory masquerading with `.mov` extension is rejected
        let fakeDir = docsDir.appendingPathComponent("folder.mov", isDirectory: true)
        try fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                fakeDir.path,
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )

        // 4. Outside file and `..` path traversal are rejected
        let outsideMov = outsideDir.appendingPathComponent("secret.mov")
        try Data("video".utf8).write(to: outsideMov)
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                outsideMov.path,
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/../../secret.mov",
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                "/etc/hosts",
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )

        // 5. Symlink inside Documents pointing outside sandbox is rejected
        let symlinkMov = docsDir.appendingPathComponent("escaped.mov")
        try fm.createSymbolicLink(at: symlinkMov, withDestinationURL: outsideMov)
        XCTAssertNil(
            SandboxPathResolver.resolveLocalFilePath(
                symlinkMov.path,
                documentsDirectory: docsDir,
                cachesDirectory: cachesDir,
                applicationSupportDirectory: appSupportDir
            )
        )
    }

    func testLANEndpointValidatorAllowsPrivateLANAndRejectsSSRF() {
        let validBases = [
            "http://192.168.1.100:8788",
            "http://10.0.0.42:8788/",
            "http://172.16.5.9:8788",
            "https://mac-studio.local:8788",
            "http://localhost:8788",
            "http://127.0.0.1:8788",
        ]
        for base in validBases {
            let url = LANEndpointValidator.validatedEndpoint(baseURLString: base, apiPath: "/api/state")
            XCTAssertNotNil(url, "Expected LAN base URL to be accepted: \(base)")
            XCTAssertEqual(url?.path, "/api/state")
        }

        let invalidBases = [
            "file:///etc/passwd",
            "ftp://192.168.1.10:21",
            "https://evil.example.com:8788",
            "http://8.8.8.8:8788",
            "http://169.254.169.254",
            "http://0.0.0.0:8788",
            "http://172.32.0.1:8788",
            "http://admin:secret@192.168.1.10:8788",
            "http://192.168.1.10:8788?redirect=https://evil.com",
            "http://192.168.1.10:8788#frag",
            "http://192.168.1.10:8788/unexpected/subpath",
        ]
        for bad in invalidBases {
            XCTAssertNil(
                LANEndpointValidator.validatedEndpoint(baseURLString: bad, apiPath: "/api/state"),
                "Expected unsafe base URL to be rejected: \(bad)"
            )
        }
    }

    func testDeepLinkValidatorSanitizesRoutesAndExtensions() {
        XCTAssertEqual(
            DeepLinkValidator.parse(URL(string: "pocketcoffee://import-latest?force=1")!),
            .importLatest
        )
        XCTAssertEqual(
            DeepLinkValidator.parse(URL(string: "pocketcoffee://report/brew-20261115-094210-p4p")!),
            .openReport("brew-20261115-094210-p4p")
        )

        XCTAssertNil(DeepLinkValidator.parse(URL(string: "pocketcoffee://report/../../etc/passwd")!))
        XCTAssertNil(DeepLinkValidator.parse(URL(string: "https://evil.example/report/123")!))
        let huge = "pocketcoffee://report/" + String(repeating: "a", count: 600)
        XCTAssertNil(DeepLinkValidator.parse(URL(string: huge)!))

        XCTAssertEqual(DeepLinkValidator.sanitizeMediaExtension("MP4"), "mp4")
        XCTAssertEqual(DeepLinkValidator.sanitizeMediaExtension("plist", fallback: "mov"), "mov")
        XCTAssertEqual(DeepLinkValidator.sanitizeMediaExtension("../sh", fallback: "mov"), "mov")
    }

    func testAnalyzerNumericOverflowAndLongInputResilience() {
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十八点五"), 18.5)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("9.2"), 9.2)
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble("999999999999999999999999999点五"))
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble("1e308"))
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble("nan"))
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble("inf"))

        // Huge extractionTimeS must not trap when formatted with safeInt
        var rec = CoffeeRecord(
            beanName: "花魁",
            beanWeightG: 18.0,
            brewMethod: "意式浓缩 (Espresso)",
            yieldG: 36.0,
            extractionTimeS: 1e40,
            pressureBar: 9.0
        )
        ChineseCoffeeAnalyzer.enrichBaristaAnalysis(&rec)
        XCTAssertFalse(rec.extractionDiagnosis.isEmpty)

        // Adversarial digit string completes quickly without catastrophic backtracking
        let tempStoreDir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-bean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempStoreDir) }
        let beanStore = BeanEquipmentStore(directoryURL: tempStoreDir)
        let start = Date()
        let longInput = String(repeating: "9", count: 22_000) + "!"
        _ = ChineseCoffeeAnalyzer.extractParameters(transcript: longInput)
        _ = beanStore.parseBeanLabelPreview(String(repeating: "9", count: 12_000) + "x")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.8)
    }

    func testWhitespaceReDoSLocatedInBilingualAndBeanLabelPatternsRunsInLinearTime() {
        let tempStoreDir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-redos-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempStoreDir) }
        let beanStore = BeanEquipmentStore(directoryURL: tempStoreDir)

        // Previously cubic O(N^3) on `String(repeating: " ", count: N) + "!"` due to optional prefix + `\s*:?\s*`
        let adversarialSpaces = String(repeating: " ", count: 18_000) + "!"
        let adversarialPrefixSpaces = "total time" + String(repeating: " ", count: 15_000) + "x"
        let adversarialDialSpaces = "setting" + String(repeating: " ", count: 15_000) + "x"
        let adversarialDateSpaces = "烘焙日期" + String(repeating: " ", count: 9_000) + "x"

        let start = Date()
        _ = ChineseCoffeeAnalyzer.extractParameters(transcript: adversarialSpaces)
        _ = ChineseCoffeeAnalyzer.extractParameters(transcript: adversarialPrefixSpaces)
        _ = AppleOnDeviceMediaRecognizer.extractVisualFields(stage: "grinding", ocrTexts: [adversarialDialSpaces])
        _ = beanStore.parseBeanLabelPreview(adversarialDateSpaces)
        _ = beanStore.parseBeanLabelPreview(String(repeating: " ", count: 9_500) + "!")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.6, "All regex patterns must finish in linear time on whitespace-heavy adversarial inputs")
    }

    func testCaptureDeviceSanitizerAndSessionSlugBlockInjectionGPSAndTraversal() {
        // 1. Control chars, newlines, BiDi overrides, and excessive length are stripped/capped
        let rawDirty = "iPhone 15 Pro\r\n<script>alert(1)</script>\u{202E}\u{0000} " + String(repeating: "X", count: 200)
        let cleaned = AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName(rawDirty)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.count, AppleOnDeviceMediaRecognizer.maxCaptureDeviceLength)
        XCTAssertFalse(cleaned!.contains("\r"))
        XCTAssertFalse(cleaned!.contains("\n"))
        XCTAssertFalse(cleaned!.contains("\0"))
        XCTAssertFalse(cleaned!.contains("\u{202E}"))

        // 2. ISO-6709 GPS coordinates, URLs, and host filesystem paths are rejected
        XCTAssertNil(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("+31.2304+121.4737+015.20/"))
        XCTAssertNil(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("-33.8688+151.2093/"))
        XCTAssertNil(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("/Users/alice/Movies/brew.mov"))
        XCTAssertNil(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("../../etc/passwd"))
        XCTAssertNil(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("https://evil.example/cam"))

        // 3. Legitimate camera models pass cleanly (including display labels like "Web / 桌面端上传")
        XCTAssertEqual(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("iPhone 15 Pro"), "iPhone 15 Pro")
        XCTAssertEqual(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("DJI Osmo Pocket 4 Pro"), "DJI Osmo Pocket 4 Pro")
        XCTAssertEqual(AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName("Web / 桌面端上传"), "Web / 桌面端上传")

        // 4. `deriveSessionSlug` must never return `.` or `..` even for dot-prefixed filenames like `..mov` or `...mov`
        let recognizer = AppleOnDeviceMediaRecognizer()
        for trickyName in ["..mov", "...mov", "....mp4", ".mov", "___", "../escape.mov"] {
            let slug = recognizer.deriveSessionSlug(from: URL(fileURLWithPath: "/tmp/\(trickyName)"))
            XCTAssertNotEqual(slug, ".")
            XCTAssertNotEqual(slug, "..")
            XCTAssertFalse(slug.isEmpty)
            XCTAssertFalse(slug.contains("/"))
            XCTAssertLessThanOrEqual(slug.count, 64)
        }
    }

    func testOCRImageBoundsAndPipelineOCRCorpusCap() async {
        // 1. Oversized photo (>2560px) and tiny low-res frame (<900px) both run safely without memory spikes or crashes
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let lowResCtx = CGContext(
            data: nil, width: 360, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let lowResImg = lowResCtx.makeImage() {
            _ = AppleOnDeviceMediaRecognizer.recognizeText(in: lowResImg)
            _ = AppleOnDeviceMediaRecognizer.classifyVisualSceneTags(in: lowResImg)
        }

        if let hugeCtx = CGContext(
            data: nil, width: 4200, height: 3100, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let hugeImg = hugeCtx.makeImage() {
            _ = AppleOnDeviceMediaRecognizer.recognizeText(in: hugeImg)
            _ = AppleOnDeviceMediaRecognizer.classifyVisualSceneTags(in: hugeImg)
        }

        // 2. Pipeline caps deduplicated keyframe OCR corpus & sanitizes untrusted sourceDevice
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-pipe-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pipeline = CoffeeIngestionPipeline(
            recordStore: RecordStore(directoryURL: tempDir),
            beanStore: BeanEquipmentStore(directoryURL: tempDir),
            advisor: RuleBasedOfflineAdvisor()
        )
        let bloatedOCR = (0..<300).map { i in "字幕行\(i)_咖啡萃取18g_" + String(repeating: "A", count: 600) }
        let kf = KeyframeObservation(stageKey: "scale_dose", stage: "称重", percentage: 10, timestampS: 2.0, ocrTexts: bloatedOCR)
        let recOut = RecognitionOutput(
            mediaKind: .video,
            mediaPath: nil,
            sourceDevice: "+31.2304+121.4737/",
            audioTranscript: "",
            transcript: "",
            speechSegments: [],
            visualFields: VisualFieldReadings(beanWeightG: 18.0),
            keyframes: [kf],
            durationS: 20.0
        )
        let result = await pipeline.generateReport(from: recOut, sourceType: .iphone, save: false)
        // GPS-like sourceDevice must fall back to safe SourceType display name
        XCTAssertEqual(result.record.cameraDevice, SourceType.iphone.displayName)
        XCTAssertLessThanOrEqual(result.record.transcript.count, 700)
    }

    func testExportDynamicCloseUpClipsHandlesNaNTimestampsAndRejectsUnsafeOutputDirectories() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pc-clips-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let dummyMov = tempDir.appendingPathComponent("clip.mov")
        try Data("not-a-real-mov".utf8).write(to: dummyMov)

        let nanKeyframes = [
            KeyframeObservation(stageKey: "scale_dose", stage: "称重", percentage: 10, timestampS: .nan, sharpnessScore: .infinity),
            KeyframeObservation(stageKey: "tamping", stage: "压粉", percentage: 50, timestampS: .infinity, sharpnessScore: .nan),
            KeyframeObservation(stageKey: "yield_timer", stage: "出杯", percentage: 90, timestampS: -5.0, sharpnessScore: 10.0),
        ]

        // Non-finite / negative timestamps are filtered cleanly without trapping
        XCTAssertTrue(AppleOnDeviceMediaRecognizer.selectLiveClipKeyframes(from: nanKeyframes, maxClips: 4).isEmpty)
        let nanExport = await AppleOnDeviceMediaRecognizer.exportDynamicCloseUpClips(
            videoURL: dummyMov,
            keyframes: nanKeyframes,
            outputDirectory: tempDir,
            maxClips: 4,
            clipDurationS: .nan
        )
        XCTAssertTrue(nanExport.isEmpty)

        // Zero/negative maxClips returns empty immediately
        let zeroExport = await AppleOnDeviceMediaRecognizer.exportDynamicCloseUpClips(
            videoURL: dummyMov,
            keyframes: [KeyframeObservation(stageKey: "tamping", stage: "压粉", percentage: 50, timestampS: 3.0)],
            outputDirectory: tempDir,
            maxClips: 0
        )
        XCTAssertTrue(zeroExport.isEmpty)

        // Path traversal & sensitive system output directories are rejected by validateWritableDirectory
        XCTAssertNil(SandboxPathResolver.validateWritableDirectory(URL(fileURLWithPath: "/etc/pocket_clips")))
        XCTAssertNil(SandboxPathResolver.validateWritableDirectory(tempDir.appendingPathComponent("../../etc")))
    }

    func testBeanStoreRejectsTraversalPhotoPathsAndHandlesExtremeBrewMetricsSafely() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pc-bean-sec-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let validPhoto = tempDir.appendingPathComponent("valid_bag.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: validPhoto)
        let secretJSON = tempDir.appendingPathComponent("bean_equipment_library.json")

        let store = BeanEquipmentStore(directoryURL: tempDir)
        let preview = store.parseBeanLabelPreview(
            "花魁 日晒 250g",
            coverImagePath: "/etc/passwd",
            photoPaths: ["../../etc/passwd", secretJSON.path, validPhoto.path]
        )
        XCTAssertEqual(preview.photoPaths, [validPhoto.path])
        XCTAssertEqual(preview.coverImagePath, validPhoto.path)

        var badEquip = store.loadLibrary().equipment
        badEquip.machinePhotoPath = "../../etc/passwd"
        badEquip.defaultWaterTempC = .infinity
        let savedEquip = store.saveEquipmentProfile(badEquip)
        XCTAssertNil(savedEquip.machinePhotoPath)
        XCTAssertEqual(savedEquip.defaultWaterTempC, 93.0)

        // Extreme extractionTimeS (1e40) in upsertBeanFromBrewRecord must never trap on Int(Double)
        let extremeRecord = CoffeeRecord(
            beanName: "安全压测豆",
            beanWeightG: 18.0,
            yieldG: 36.0,
            extractionTimeS: 1e40
        )
        let upserted = store.upsertBeanFromBrewRecord(extremeRecord)
        XCTAssertNotNil(upserted)
    }

    func testLANEndpointValidatorRejectsOctalIPv4AndMalformedIPv6() {
        // Leading-zero IPv4 octets can be interpreted as octal (010.0.0.1 -> 8.0.0.1 public IP)
        XCTAssertNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://010.0.0.1:8788", apiPath: "/api/state"))
        XCTAssertNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://192.168.01.1:8788", apiPath: "/api/state"))

        // Malformed or link-local/public IPv6 addresses must be rejected; ::1 and valid ULA fd00::/8 accepted
        XCTAssertNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://[fc:]:8788", apiPath: "/api/state"))
        XCTAssertNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://[fd00::1::2]:8788", apiPath: "/api/state"))
        XCTAssertNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://[fe80::1]:8788", apiPath: "/api/state"))
        XCTAssertNotNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://[::1]:8788", apiPath: "/api/state"))
        XCTAssertNotNil(LANEndpointValidator.validatedEndpoint(baseURLString: "http://[fd12:3456:789a::1]:8788", apiPath: "/api/state"))

        // Deep link with embedded user credentials must be rejected
        XCTAssertNil(DeepLinkValidator.parse(URL(string: "pocketcoffee://user:pass@import-latest")!))
    }
}

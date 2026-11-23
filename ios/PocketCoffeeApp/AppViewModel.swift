import Foundation
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import PocketCoffeeCore
#if canImport(UIKit)
import UIKit
#endif

enum AppTab: Hashable {
    case ingest
    case reports
    case beansEquipment
    case onDeviceAI
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .ingest
    @Published var selectedRecordID: String?
    @Published var reportNavigationPath: [String] = []

    @Published var records: [CoffeeRecord] = []
    @Published var beanLibrary: BeanEquipmentLibrary = BeanEquipmentLibrary()
    @Published var capabilities: OnDeviceAICapabilities = OnDeviceAICapabilities.currentCapabilities()

    @Published var isBusy: Bool = false
    @Published var busyLabel: String = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    @Published var lastRecognitionPreview: RecognitionOutput?
    @Published var editableTranscript: String = ""
    @Published var editableVisualFields: VisualFieldReadings = VisualFieldReadings()

    // On-device voice memo recording state
    @Published var isRecordingAudio: Bool = false
    @Published var recordingDurationS: Double = 0
    @Published var recordedAudioURL: URL?

    // Optional LAN sync to Mac Hub (:8788)
    @Published var lanSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(lanSyncEnabled, forKey: Self.lanSyncEnabledKey) }
    }
    @Published var macHubBaseURL: String {
        didSet { UserDefaults.standard.set(macHubBaseURL, forKey: Self.macHubURLKey) }
    }
    @Published var isSyncingToMac: Bool = false
    @Published var lastSyncSummary: String?

    private let dataDirectoryURL: URL
    private let mediaDirectoryURL: URL
    private let recordStore: RecordStore
    private let beanStore: BeanEquipmentStore
    private let pipeline: CoffeeIngestionPipeline

    #if os(iOS)
    private var audioRecorder: AVAudioRecorder?
    #endif
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var messageAutoDismissTask: Task<Void, Never>?

    private static let lanSyncEnabledKey = "pocket_coffee_lan_sync_enabled"
    private static let macHubURLKey = "pocket_coffee_mac_hub_url"
    private static let maxImportedMediaBytes: Int64 = 1_073_741_824
    private var lastDeepLinkImportAt: Date?

    private static func applySandboxFileProtection(at url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func makeLANURLSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 3
        return URLSession(configuration: cfg, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
    }

    init(dataDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let custom = dataDirectoryURL {
            baseDir = custom
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            baseDir = docs.appendingPathComponent("PocketCoffeeData", isDirectory: true)
        }
        let mediaDir = baseDir.appendingPathComponent("Media", isDirectory: true)
        let keyframesDir = baseDir.appendingPathComponent("Keyframes", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keyframesDir, withIntermediateDirectories: true)
        Self.applySandboxFileProtection(at: baseDir)
        Self.applySandboxFileProtection(at: mediaDir)
        Self.applySandboxFileProtection(at: keyframesDir)

        self.dataDirectoryURL = baseDir
        self.mediaDirectoryURL = mediaDir
        self.recordStore = RecordStore(directoryURL: baseDir)
        self.beanStore = BeanEquipmentStore(directoryURL: baseDir)
        let recognizer = AppleOnDeviceMediaRecognizer(
            keyframeBaseDirectory: keyframesDir,
            knownBeans: self.beanStore.loadLibrary().beans
        )
        self.pipeline = CoffeeIngestionPipeline(
            recordStore: self.recordStore,
            beanStore: self.beanStore,
            recognizer: recognizer
        )

        self.lanSyncEnabled = UserDefaults.standard.bool(forKey: Self.lanSyncEnabledKey)
        self.macHubBaseURL = UserDefaults.standard.string(forKey: Self.macHubURLKey) ?? "http://192.168.1.100:8788"

        let existingRecords = self.recordStore.listRecords()
        self.beanStore.backfillBeansFromRecords(existingRecords)
        self.beanStore.backfillEquipmentFromRecords(existingRecords)
        refreshAll()
    }

    func refreshAll() {
        records = recordStore.listRecords()
        beanLibrary = beanStore.loadLibrary()
        capabilities = OnDeviceAICapabilities.currentCapabilities()
    }

    func refreshCapabilities() {
        capabilities = OnDeviceAICapabilities.currentCapabilities()
        showStatus("已刷新端侧 AI 引擎状态")
    }

    func clearMessages() {
        messageAutoDismissTask?.cancel()
        messageAutoDismissTask = nil
        statusMessage = nil
        errorMessage = nil
    }

    func showStatus(_ message: String) {
        messageAutoDismissTask?.cancel()
        errorMessage = nil
        statusMessage = message
        messageAutoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.statusMessage == message {
                self?.statusMessage = nil
            }
        }
    }

    func showError(_ message: String) {
        messageAutoDismissTask?.cancel()
        statusMessage = nil
        errorMessage = message
        messageAutoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.errorMessage == message {
                self?.errorMessage = nil
            }
        }
    }

    // MARK: - Persistent Media Import Helper

    func importMediaFile(from sourceURL: URL, suggestedExtension: String? = nil) -> URL? {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            showError("所选媒体文件无效或受限")
            return nil
        }
        if let fileSize = values.fileSize, Int64(fileSize) > Self.maxImportedMediaBytes {
            showError("媒体文件超过 1GB 安全导入上限")
            return nil
        }
        let rawExt = suggestedExtension ?? sourceURL.pathExtension
        let ext = DeepLinkValidator.sanitizeMediaExtension(rawExt, fallback: "mov")
        let filename = "media-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        let destination = mediaDirectoryURL.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            Self.applySandboxFileProtection(at: destination)
            return destination
        } catch {
            showError("导入媒体文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Recognition & Ingestion Pipeline

    func runRecognitionPreview(
        mediaURL: URL?,
        spokenTranscript: String,
        sourceType: SourceType,
        hintOverrides: VisualFieldReadings? = nil
    ) async {
        let trimmed = spokenTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mediaURL != nil || !trimmed.isEmpty else {
            showError("请先选择视频/音频、录制语音或输入冲煮笔记")
            return
        }

        isBusy = true
        busyLabel = "正在端侧识别语音与画面关键帧..."
        clearMessages()
        defer {
            isBusy = false
            busyLabel = ""
        }

        let output = await pipeline.recognizeMedia(
            mediaURL: mediaURL,
            spokenTranscript: trimmed,
            sourceDevice: sourceType.displayName,
            hintOverrides: hintOverrides,
            extractFrames: true
        )

        lastRecognitionPreview = output
        editableTranscript = output.transcript
        editableVisualFields = output.visualFields
        showStatus("端侧识别完成：提取 \(output.keyframes.count) 个关键帧")
    }

    func generateFromPreview(
        sourceType: SourceType,
        recordIntent: RecordIntent
    ) async {
        guard var preview = lastRecognitionPreview else {
            showError("当前没有可生成的识别预览")
            return
        }

        isBusy = true
        busyLabel = "正在端侧生成报告与风味分析..."
        clearMessages()
        defer {
            isBusy = false
            busyLabel = ""
        }

        preview.transcript = editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.visualFields = editableVisualFields

        let result = await pipeline.generateReport(
            from: preview,
            sourceType: sourceType,
            recordIntent: recordIntent,
            save: true
        )

        handlePipelineResult(result)
    }

    func runOneClickIngest(
        mediaURL: URL?,
        spokenTranscript: String,
        sourceType: SourceType,
        recordIntent: RecordIntent,
        hintOverrides: VisualFieldReadings? = nil
    ) async {
        let trimmed = spokenTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mediaURL != nil || !trimmed.isEmpty else {
            showError("请先选择视频/音频、录制语音或输入冲煮笔记")
            return
        }

        isBusy = true
        busyLabel = "正在端侧识别并生成专属咖啡记录..."
        clearMessages()
        defer {
            isBusy = false
            busyLabel = ""
        }

        let result = await pipeline.ingestMedia(
            mediaURL: mediaURL,
            spokenTranscript: trimmed,
            sourceDevice: sourceType.displayName,
            sourceType: sourceType,
            recordIntent: recordIntent,
            hintOverrides: hintOverrides,
            extractFrames: true,
            save: true
        )

        lastRecognitionPreview = result.recognition
        editableTranscript = result.recognition.transcript
        editableVisualFields = result.recognition.visualFields
        handlePipelineResult(result)
    }

    private func handlePipelineResult(_ result: PipelineResult) {
        if result.rejectedAsNonCoffee || !result.saved {
            showError(result.rejectionReason ?? "未检测到咖啡制作或器具相关内容，已自动拦截，未写入档案库。")
            return
        }

        refreshAll()
        openReport(id: result.record.id)
        AppNotificationManager.shared.notifyReportReady(record: result.record)

        if result.record.recordType == .equipmentProfile {
            showStatus("设备档案已生成并更新至永久设备库")
        } else if let deducted = result.deductedBean {
            showStatus("咖啡报告已生成，已自动扣减「\(deducted.fullName)」余量")
        } else {
            showStatus("咖啡报告已生成（引擎：\(result.advisorBackend)）")
        }

        if lanSyncEnabled {
            let recordToSync = result.record
            Task {
                await syncRecordToMacHub(recordToSync)
            }
        }
    }

    // MARK: - Deep-Link Navigation & iPhone Shortcuts Automation

    func openReport(id: String) {
        guard let safeID = DeepLinkValidator.sanitizeRecordID(id) else { return }
        refreshAll()
        guard record(for: safeID) != nil else { return }
        selectedTab = .reports
        selectedRecordID = safeID
        reportNavigationPath = [safeID]
    }

    func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkValidator.parse(url) else { return }
        switch route {
        case .importLatest:
            let now = Date()
            if let last = lastDeepLinkImportAt, now.timeIntervalSince(last) < 3.0 {
                return
            }
            lastDeepLinkImportAt = now
            Task {
                await importLatestPhotoVideoAndGenerate(skipIfAlreadyImported: true)
            }
        case .openReport(let recordID):
            openReport(id: recordID)
        }
    }

    func importLatestPhotoVideoAndGenerate(skipIfAlreadyImported: Bool = true) async {
        guard !isBusy else { return }
        selectedTab = .ingest
        isBusy = true
        busyLabel = "快捷指令触发：正在自动读取相册最新视频..."
        clearMessages()

        #if canImport(UIKit)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "PocketCoffeeAutoIngest") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        #endif

        defer {
            isBusy = false
            busyLabel = ""
        }

        do {
            let fetched = try await LatestPhotoVideoFetcher.fetchLatestVideo(
                destinationDirectory: mediaDirectoryURL,
                skipIfAlreadyImported: skipIfAlreadyImported
            )
            busyLabel = "已导入最新视频，正在端侧识别并生成报告..."
            let result = await pipeline.ingestMedia(
                mediaURL: fetched.fileURL,
                spokenTranscript: "",
                sourceDevice: SourceType.iphone.displayName,
                sourceType: .iphone,
                recordIntent: .auto,
                extractFrames: true,
                save: true
            )
            lastRecognitionPreview = result.recognition
            editableTranscript = result.recognition.transcript
            editableVisualFields = result.recognition.visualFields
            handlePipelineResult(result)
        } catch let fetchErr as LatestPhotoVideoFetcher.FetchError where fetchErr == .alreadyImported {
            showStatus(fetchErr.localizedDescription)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Records CRUD & Supplement

    @discardableResult
    func supplementRecord(
        id: String,
        supplementText: String,
        updates: [String: String]
    ) -> CoffeeRecord? {
        let updated = pipeline.supplementRecord(
            id: id,
            supplementText: supplementText,
            updates: updates
        )
        if let updated {
            refreshAll()
            showStatus("已补全参数并重新生成诊断")
            return updated
        } else {
            showError("未能更新该记录，请稍后重试")
            return nil
        }
    }

    func deleteRecord(id: String) {
        recordStore.deleteRecord(id: id)
        if selectedRecordID == id {
            selectedRecordID = nil
        }
        refreshAll()
        showStatus("已删除记录")
    }

    func record(for id: String) -> CoffeeRecord? {
        records.first(where: { $0.id == id }) ?? recordStore.getRecord(id: id)
    }

    // MARK: - Beans & Equipment

    @discardableResult
    func parseAndAddBean(labelText: String) -> BeanEntry? {
        let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("请先粘贴或输入豆袋标签文字")
            return nil
        }
        let parsed = beanStore.parseBeanLabelText(trimmed)
        _ = beanStore.addOrUpdateBean(parsed)
        refreshAll()
        showStatus("已解析并入库：\(parsed.fullName)")
        return parsed
    }

    func saveBean(_ bean: BeanEntry) {
        _ = beanStore.addOrUpdateBean(bean)
        refreshAll()
        showStatus("已保存咖啡豆：\(bean.fullName)")
    }

    #if canImport(UIKit)
    private static let maxBeanBagPhotos = 4

    /// Downsamples oversized camera/library photos to at most `2048` px on the longest edge
    /// and re-encodes a clean JPEG via ImageIO without copying EXIF/GPS/MakerNote metadata.
    private static func normalizedSanitizedJPEG(
        from uiImage: UIImage,
        maxDimension: CGFloat = 2048,
        quality: CGFloat = 0.85
    ) -> (data: Data, cgImage: CGImage)? {
        let pixelW = uiImage.size.width * uiImage.scale
        let pixelH = uiImage.size.height * uiImage.scale
        guard pixelW.isFinite, pixelH.isFinite, pixelW >= 1, pixelH >= 1,
              pixelW <= 16_384, pixelH <= 16_384
        else {
            return nil
        }

        let longest = max(pixelW, pixelH)
        let scaleFactor = longest > maxDimension ? (maxDimension / longest) : 1.0
        let targetSize = CGSize(
            width: max(1, (pixelW * scaleFactor).rounded()),
            height: max(1, (pixelH * scaleFactor).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let cgImage = rendered.cgImage else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest), mutableData.length > 0 else {
            return nil
        }
        return (mutableData as Data, cgImage)
    }

    func scanBeanBagPhoto(_ uiImage: UIImage) async -> BeanBagScanResult? {
        await scanBeanBagPhotos([uiImage])
    }

    /// Saves 1..4 coffee bean bag photos (e.g., front + back) locally with EXIF stripped
    /// and sandbox file protection applied, runs 100% on-device Vision OCR on every photo,
    /// combines all extracted text, checks for existing matching beans, and returns a unified `BeanBagScanResult`.
    func scanBeanBagPhotos(_ images: [UIImage]) async -> BeanBagScanResult? {
        let boundedImages = Array(images.prefix(Self.maxBeanBagPhotos))
        guard !boundedImages.isEmpty else { return nil }
        let photosDir = dataDirectoryURL.appendingPathComponent("BeanPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        Self.applySandboxFileProtection(at: photosDir)

        var savedPaths: [String] = []
        var cgImages: [CGImage] = []
        let ts = Int(Date().timeIntervalSince1970)

        for (idx, uiImage) in boundedImages.enumerated() {
            let filename = "bean-bag-\(ts)-\(idx + 1)-\(UUID().uuidString.prefix(4).lowercased()).jpg"
            let destURL = photosDir.appendingPathComponent(filename)
            guard let prepared = Self.normalizedSanitizedJPEG(from: uiImage, quality: 0.85) else { continue }
            do {
                #if os(iOS)
                try prepared.data.write(to: destURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try prepared.data.write(to: destURL, options: .atomic)
                #endif
                Self.applySandboxFileProtection(at: destURL)
                savedPaths.append(destURL.path)
                cgImages.append(prepared.cgImage)
            } catch {
                continue
            }
        }

        guard !savedPaths.isEmpty else {
            showError("无法保存豆袋照片，请重试")
            return nil
        }

        let allLines: [String] = await Task.detached(priority: .userInitiated) {
            var collected: [String] = []
            for cg in cgImages {
                collected.append(contentsOf: AppleOnDeviceMediaRecognizer.recognizeText(in: cg))
            }
            return collected
        }.value

        let joined = String(allLines.joined(separator: "\n").prefix(10_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = beanStore.parseBeanLabelPreview(joined, coverImagePath: savedPaths.first, photoPaths: savedPaths)
        let matched = beanStore.findMatchingBeanForScan(rawText: joined, parsedBean: parsed)

        if let matched {
            showStatus("检测到豆库已有「\(matched.fullName)」，可在弹窗中选择补全当前袋、复购累加或另存新豆")
        } else if joined.isEmpty {
            showStatus("已保存 \(savedPaths.count) 张豆袋照片（未识别到清晰文字，可点击卡片手动补充）")
        } else {
            showStatus("已合并识别 \(savedPaths.count) 张豆袋图（共 \(allLines.count) 行信息）")
        }
        return BeanBagScanResult(ocrText: joined, scannedBean: parsed, matchedExistingBean: matched)
    }

    /// Saves a coffee machine photo locally (EXIF-stripped, downsampled, and file-protected)
    /// and persists it into `EquipmentProfile.machinePhotoPath`.
    @discardableResult
    func saveMachinePhoto(_ uiImage: UIImage) -> String? {
        let dir = dataDirectoryURL.appendingPathComponent("EquipmentPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applySandboxFileProtection(at: dir)
        let filename = "machine-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4).lowercased()).jpg"
        let destURL = dir.appendingPathComponent(filename)
        guard let prepared = Self.normalizedSanitizedJPEG(from: uiImage, quality: 0.85) else {
            showError("无法处理咖啡机照片，请重试")
            return nil
        }
        do {
            let previousPath = beanStore.loadLibrary().equipment.machinePhotoPath
            #if os(iOS)
            try prepared.data.write(to: destURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try prepared.data.write(to: destURL, options: .atomic)
            #endif
            Self.applySandboxFileProtection(at: destURL)
            var profile = beanStore.loadLibrary().equipment
            profile.machinePhotoPath = destURL.path
            _ = beanStore.saveEquipmentProfile(profile)
            if let oldPath = previousPath,
               oldPath != destURL.path,
               oldPath.hasPrefix(dir.resolvingSymlinksInPath().path + "/") || oldPath.hasPrefix(dir.path + "/") {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            refreshAll()
            showStatus("咖啡机照片已更新")
            return destURL.path
        } catch {
            showError("保存咖啡机照片失败：\(error.localizedDescription)")
            return nil
        }
    }
    #endif

    func deleteBean(id: String) {
        beanStore.deleteBean(id: id)
        refreshAll()
        showStatus("已从咖啡豆库移除")
    }

    func deleteBeans(ids: Set<String>) {
        let removed = beanStore.deleteBeans(ids: ids)
        refreshAll()
        if removed > 0 {
            showStatus("已批量删除 \(removed) 款咖啡豆")
        }
    }

    func clearSampleBeans() {
        let removed = beanStore.removeSeededSampleBeans()
        refreshAll()
        if removed > 0 {
            showStatus("已清理 \(removed) 条示例咖啡豆，保留你的真实豆库")
        }
    }

    func saveEquipmentProfile(_ profile: EquipmentProfile, silent: Bool = false) {
        _ = beanStore.saveEquipmentProfile(profile)
        refreshAll()
        if !silent {
            showStatus("永久设备档案已保存")
        }
    }

    // MARK: - On-Device Voice Recording (iOS)

    func toggleVoiceRecording() {
        if isRecordingAudio {
            stopVoiceRecording()
        } else {
            startVoiceRecording()
        }
    }

    func startVoiceRecording() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            showError("无法启动麦克风会话：\(error.localizedDescription)")
            return
        }

        let filename = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = mediaDirectoryURL.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                showError("录音启动失败，请检查麦克风权限")
                return
            }
            audioRecorder = recorder
            recordedAudioURL = fileURL
            isRecordingAudio = true
            recordingStartDate = Date()
            recordingDurationS = 0
            clearMessages()

            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let start = self.recordingStartDate else { return }
                    self.recordingDurationS = Date().timeIntervalSince(start)
                }
            }
        } catch {
            showError("初始化录音器失败：\(error.localizedDescription)")
        }
        #else
        showError("当前平台不支持 iOS 端侧录音")
        #endif
    }

    func stopVoiceRecording() {
        #if os(iOS)
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecordingAudio = false
        if let url = recordedAudioURL {
            Self.applySandboxFileProtection(at: url)
            showStatus("已录制语音备忘录（\(String(format: "%.1f", recordingDurationS))s）：\(url.lastPathComponent)")
        }
    }

    // MARK: - Optional LAN Sync to Mac Hub (:8788)

    func syncRecordToMacHub(_ record: CoffeeRecord) async {
        guard let endpoint = LANEndpointValidator.validatedEndpoint(
            baseURLString: macHubBaseURL,
            apiPath: "/api/ingest/process"
        ) else {
            lastSyncSummary = "Mac 中枢地址无效或非局域网地址：\(macHubBaseURL)"
            return
        }

        isSyncingToMac = true
        defer { isSyncingToMac = false }

        var hintOverrides: [String: Any] = [:]
        if let v = record.beanName { hintOverrides["bean_name"] = v }
        if let v = record.beanWeightG { hintOverrides["bean_weight_g"] = v }
        if let v = record.grindSetting { hintOverrides["grind_setting"] = v }
        if let v = record.grinderModel { hintOverrides["grinder_model"] = v }
        if let v = record.pressureBar { hintOverrides["pressure_bar"] = v }
        if let v = record.waterTempC { hintOverrides["water_temp_c"] = v }
        if let v = record.yieldG { hintOverrides["yield_g"] = v }
        if let v = record.extractionTimeS { hintOverrides["extraction_time_s"] = v }

        let payload: [String: Any] = [
            "transcript": record.transcript,
            "source_type": record.sourceType.rawValue,
            "source_device": record.cameraDevice,
            "record_intent": record.recordType.rawValue,
            "hint_overrides": hintOverrides,
            "save": true,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let session = Self.makeLANURLSession(timeout: 12)
        defer { session.finishTasksAndInvalidate() }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                lastSyncSummary = "已同步至 Mac 中枢（HTTP \(http.statusCode)）"
                showStatus("已同步记录到 Mac 局域网中枢")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastSyncSummary = "同步返回异常状态码：\(code)"
            }
        } catch {
            lastSyncSummary = "局域网同步失败：\(error.localizedDescription)"
        }
    }

    func testMacHubConnection() async {
        guard let url = LANEndpointValidator.validatedEndpoint(
            baseURLString: macHubBaseURL,
            apiPath: "/api/state"
        ) else {
            lastSyncSummary = "拒绝非局域网或格式错误的地址"
            showError("请输入有效的局域网地址（仅支持私有 LAN IP 或 .local，例如 http://192.168.1.100:8788）")
            return
        }

        isSyncingToMac = true
        defer { isSyncingToMac = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let session = Self.makeLANURLSession(timeout: 6)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                lastSyncSummary = "连接成功：Mac 局域网中枢在线"
                showStatus("Mac 局域网中枢连接成功")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastSyncSummary = "连接异常：HTTP \(code)"
                showError("Mac 中枢返回状态码 \(code)")
            }
        } catch {
            lastSyncSummary = "无法连接到 Mac 中枢：\(error.localizedDescription)"
            showError("无法连接到 Mac 中枢，请确认在同一局域网且服务已启动")
        }
    }
}

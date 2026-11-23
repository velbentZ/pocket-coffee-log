import AppIntents
import AVFoundation
import Foundation
import Photos
import PocketCoffeeCore

extension Notification.Name {
    static let pocketCoffeeTriggerImportLatest = Notification.Name("pocketCoffeeTriggerImportLatest")
}

/// Native iOS Shortcuts / Siri AppIntent:
/// Automatically grabs the latest recorded video from iPhone Photos and starts on-device report generation.
/// Can be bound to:
/// - Shortcuts Personal Automation ("When Camera App is Closed" -> Run Immediately)
/// - iPhone 15 Pro Action Button / Back Tap / Lock Screen Widget / Siri
@available(iOS 17.0, *)
struct ImportLatestBrewVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "导入最新咖啡视频并生成报告"
    static var description = IntentDescription("自动读取相册中最新录制的一条视频，在端侧离线识别并生成咖啡制作报告（非咖啡视频会自动拦截跳过）。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .pocketCoffeeTriggerImportLatest, object: nil)
        return .result(dialog: "正在自动导入最新视频并在端侧生成咖啡报告，完成后会发通知提醒你。")
    }
}

@available(iOS 17.0, *)
struct PocketCoffeeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ImportLatestBrewVideoIntent(),
            phrases: [
                "用\(.applicationName)导入最新咖啡视频",
                "用\(.applicationName)分析刚才拍的咖啡",
                "在\(.applicationName)生成咖啡报告",
            ],
            shortTitle: "导入最新咖啡视频",
            systemImageName: "cup.and.saucer.fill"
        )
    }
}

/// Helper to fetch the newest video asset from iPhone Photos Library for zero-tap Shortcut automation.
enum LatestPhotoVideoFetcher {
    struct FetchedVideo {
        let assetID: String
        let creationDate: Date?
        let fileURL: URL
    }

    enum FetchError: LocalizedError {
        case permissionDenied
        case noVideoFound
        case alreadyImported
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "请在系统「设置 → 隐私 → 照片」授予访问相册权限以启用自动导入。"
            case .noVideoFound:
                return "相册中未找到最近录制的视频。"
            case .alreadyImported:
                return "相册最新一条视频已经分析过了（未检测到新录制的视频）。"
            case .exportFailed:
                return "读取相册最新视频失败（若视频仅在 iCloud，请稍候重试）。"
            }
        }
    }

    private static let lastAutoImportedKey = "pocketcoffee.lastAutoImportedAssetID"

    static func fetchLatestVideo(
        destinationDirectory: URL,
        skipIfAlreadyImported: Bool = true
    ) async throws -> FetchedVideo {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw FetchError.permissionDenied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .video, options: options)
        guard let asset = assets.firstObject else {
            throw FetchError.noVideoFound
        }

        let assetID = asset.localIdentifier
        if skipIfAlreadyImported,
           UserDefaults.standard.string(forKey: lastAutoImportedKey) == assetID {
            throw FetchError.alreadyImported
        }

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            let reqOptions = PHVideoRequestOptions()
            reqOptions.version = .current
            reqOptions.deliveryMode = .highQualityFormat
            reqOptions.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: reqOptions) { av, _, _ in
                continuation.resume(returning: av)
            }
        }

        guard let urlAsset = avAsset as? AVURLAsset else {
            throw FetchError.exportFailed
        }
        if let vals = try? urlAsset.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            guard vals.isRegularFile == true, vals.isSymbolicLink != true else {
                throw FetchError.exportFailed
            }
            if let size = vals.fileSize, Int64(size) > 1_073_741_824 {
                throw FetchError.exportFailed
            }
        }

        let ext = DeepLinkValidator.sanitizeMediaExtension(urlAsset.url.pathExtension, fallback: "mov")
        let filename = "auto-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        let destURL = destinationDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: urlAsset.url, to: destURL)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destURL.path
        )
        #endif
        UserDefaults.standard.set(assetID, forKey: lastAutoImportedKey)
        return FetchedVideo(assetID: assetID, creationDate: asset.creationDate, fileURL: destURL)
    }
}

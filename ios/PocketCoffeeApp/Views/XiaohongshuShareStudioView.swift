import AVFoundation
import AVKit
import Photos
import PocketCoffeeCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Xiaohongshu (小红书) One-Tap Editorial Carousel & Close-Up Clip Export Studio.
/// Automatically composes 3:4 (1080×1440) magazine-grade cover + per-keyframe close-up cards
/// (coffee machine, beans/scale, grinder dial, extraction crema) and optional 2.5s dynamic
/// close-up MOV clips from the original video so the user can post with zero secondary editing.
struct XiaohongshuShareStudioView: View {
    let record: CoffeeRecord

    @Environment(\.dismiss) private var dismiss

    @State private var includeCoverCard: Bool = true
    @State private var removedKeyframeIDs: Set<String> = []
    @State private var removedClipKeyframeIDs: Set<String> = []
    @State private var customStageTitles: [String: String] = [:]
    @State private var editableTitle: String = ""
    @State private var editableBody: String = ""
    @State private var isExporting: Bool = false
    @State private var exportStatus: String?
    @State private var exportError: String?
    @State private var lastSavedSelectionSignature: String?
    @State private var previewCardIndex: Int?
    @State private var copiedTarget: String?

    #if canImport(UIKit)
    @State private var shareItems: [Any] = []
    @State private var showSystemShareSheet: Bool = false
    #endif

    private static let craftStagePresets: [String] = [
        "称重豆量",
        "磨豆出粉",
        "接粉称重",
        "布粉针打散结块",
        "布粉器压平",
        "压粉锤压粉",
        "咖啡机萃取",
        "成品出杯",
        "咖啡机特写",
        "咖啡豆特写",
    ]

    private var extractedKeyframes: [KeyframeObservation] {
        SandboxPathResolver.exportableXiaohongshuKeyframes(for: record)
    }

    private var keptKeyframes: [KeyframeObservation] {
        extractedKeyframes.filter { !removedKeyframeIDs.contains($0.id) }
    }

    private var availableClipKeyframes: [KeyframeObservation] {
        guard hasLocalSourceVideo, !extractedKeyframes.isEmpty else { return [] }
        return AppleOnDeviceMediaRecognizer.selectLiveClipKeyframes(from: extractedKeyframes, maxClips: 4)
    }

    private var keptClipKeyframes: [KeyframeObservation] {
        availableClipKeyframes.filter { !removedClipKeyframeIDs.contains($0.id) }
    }

    private var removedCount: Int {
        (includeCoverCard ? 0 : 1) + removedKeyframeIDs.count + removedClipKeyframeIDs.count
    }

    private var resolvedSourceVideoPath: String? {
        guard record.mediaKind == .video else { return nil }
        return SandboxPathResolver.resolveLocalFilePath(record.videoPath)
    }

    private var hasLocalSourceVideo: Bool {
        resolvedSourceVideoPath != nil
    }

    private var totalSelectedCards: Int {
        (includeCoverCard ? 1 : 0) + keptKeyframes.count
    }

    private var dynamicClipCount: Int {
        keptClipKeyframes.count
    }

    private var totalSelectedItems: Int {
        totalSelectedCards + dynamicClipCount
    }

    private var exportAssetSummaryText: String {
        if totalSelectedCards > 0 && dynamicClipCount > 0 {
            return "\(totalSelectedCards) 张图 + \(dynamicClipCount) 段实况"
        } else if dynamicClipCount > 0 {
            return "\(dynamicClipCount) 段特写实况"
        }
        return "\(totalSelectedCards) 张图"
    }

    private var currentSelectionSignature: String {
        let kfPart = keptKeyframes.map { kf in
            "\(kf.id):\(customStageTitles[kf.id] ?? "")"
        }.joined(separator: ",")
        let clipPart = keptClipKeyframes.map(\.id).joined(separator: ",")
        return "\(includeCoverCard)|\(kfPart)|clips:\(clipPart)"
    }

    private var isCurrentSelectionAlreadySaved: Bool {
        lastSavedSelectionSignature == currentSelectionSignature
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    studioHeaderCard
                    carouselPreviewSection
                    copyEditorSection
                    actionButtonsSection
                }
                .padding(16)
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .navigationTitle("小红书一键排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                }
            }
            .onAppear {
                splitInitialCopy()
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showSystemShareSheet) {
                ActivityShareSheet(items: shareItems)
            }
            #endif
            .fullScreenCover(
                isPresented: Binding(
                    get: { previewCardIndex != nil },
                    set: { if !$0 { previewCardIndex = nil } }
                )
            ) {
                XiaohongshuCardPreviewOverlay(
                    record: record,
                    sourceVideoURL: resolvedSourceVideoPath.map(URL.init(fileURLWithPath:)),
                    includeCoverCard: $includeCoverCard,
                    keptKeyframes: keptKeyframes,
                    removedKeyframeIDs: $removedKeyframeIDs,
                    keptClipKeyframes: keptClipKeyframes,
                    removedClipKeyframeIDs: $removedClipKeyframeIDs,
                    customStageTitles: customStageTitles,
                    initialIndex: previewCardIndex ?? 0,
                    onClose: { previewCardIndex = nil }
                )
            }
        }
    }

    // MARK: - Sections

    private var studioHeaderCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.title2)
                .foregroundStyle(CoffeeTheme.cremaAccent)
                .frame(width: 44, height: 44)
                .background(CoffeeTheme.cremaAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("3:4 杂志风自动排版 · 一步到位")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.warmText)
                Text("自动生成 1080×1440 封面总览卡 + \(extractedKeyframes.count) 张视频特写分镜卡，无需二次修图即可直发小红书。")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoffeeTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CoffeeTheme.cremaAccent.opacity(0.22), lineWidth: 1)
        )
    }

    private var carouselPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("图组排版预览（\(exportAssetSummaryText)）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                if removedCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            includeCoverCard = true
                            removedKeyframeIDs.removeAll()
                            removedClipKeyframeIDs.removeAll()
                        }
                    } label: {
                        Label("恢复已删(\(removedCount))", systemImage: "arrow.uturn.backward.circle")
                            .font(.caption2.weight(.semibold))
                    }
                    .tint(CoffeeTheme.cremaAccent)
                } else {
                    Text("点图预览 · × 删除")
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Card 1: 3:4 Cover Poster
                    if includeCoverCard {
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                XiaohongshuCoverPosterView(
                                    record: record,
                                    keyframes: keptKeyframes,
                                    customTitles: customStageTitles
                                )
                                .frame(width: 225, height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(CoffeeTheme.cremaAccent, lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    previewCardIndex = 0
                                }

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        includeCoverCard = false
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, CoffeeTheme.dangerRed)
                                        .padding(6)
                                }
                                .accessibilityLabel("删除封面图")
                            }

                            Text("图 1 · 封面总览")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(CoffeeTheme.cremaAccent)
                        }
                    }

                    // Card 2..N: Per-Keyframe 3:4 Close-Up Cards
                    ForEach(Array(keptKeyframes.enumerated()), id: \.element.id) { idx, kf in
                        let displayNum = (includeCoverCard ? 2 : 1) + idx
                        let currentLabel = customStageTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile)
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                XiaohongshuKeyframeCardView(
                                    record: record,
                                    keyframe: kf,
                                    index: idx + 1,
                                    overrideTitle: customStageTitles[kf.id]
                                )
                                .frame(width: 225, height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(CoffeeTheme.cremaAccent.opacity(0.85), lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    previewCardIndex = (includeCoverCard ? 1 : 0) + idx
                                }

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        _ = removedKeyframeIDs.insert(kf.id)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, CoffeeTheme.dangerRed)
                                        .padding(6)
                                }
                                .accessibilityLabel("删除图 \(displayNum)")
                            }

                            Menu {
                                ForEach(Self.craftStagePresets, id: \.self) { preset in
                                    Button(preset) {
                                        customStageTitles[kf.id] = preset
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("图 \(displayNum) · \(currentLabel)")
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(CoffeeTheme.cremaLight)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(CoffeeTheme.cardElevated, in: Capsule())
                            }
                        }
                    }

                    // Inline 2.5s Dynamic Close-Up Video Cards (ON by default, previewable & removable)
                    ForEach(Array(keptClipKeyframes.enumerated()), id: \.element.id) { clipIdx, kf in
                        let clipLabel = customStageTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile)
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                XiaohongshuClipThumbnailCard(
                                    keyframe: kf,
                                    stageTitle: clipLabel,
                                    clipNumber: clipIdx + 1
                                )
                                .frame(width: 225, height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(CoffeeTheme.warningAmber.opacity(0.9), lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    previewCardIndex = totalSelectedCards + clipIdx
                                }

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        _ = removedClipKeyframeIDs.insert(kf.id)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, CoffeeTheme.dangerRed)
                                        .padding(6)
                                }
                                .accessibilityLabel("删除实况 \(clipIdx + 1)")
                            }

                            HStack(spacing: 4) {
                                Image(systemName: "livephoto.play")
                                    .font(.caption2)
                                Text("实况 \(clipIdx + 1) · \(clipLabel)")
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CoffeeTheme.warningAmber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(CoffeeTheme.warningAmber.opacity(0.14), in: Capsule())
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if extractedKeyframes.isEmpty {
                Text("本次记录未包含视频关键帧（如纯语音或文字记录），将自动生成 3:4 杂志风图文参数卡片供发布。")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            } else {
                Text("💡 已自动编排 3:4 精排图与 2.5 秒特写实况片段；点击任意卡片可全屏预览/播放，点右上角红色 × 可单独移除。")
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(14)
        .background(CoffeeTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var copyEditorSection: some View {
        let titleCount = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("小红书文案（标题与正文可分开一键复制）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                Button {
                    copyText(combinedCopy, targetKey: "all", status: "已复制完整标题与正文")
                } label: {
                    Label(copiedTarget == "all" ? "已复制全部" : "复制全部", systemImage: copiedTarget == "all" ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            copiedTarget == "all" ? CoffeeTheme.successGreen.opacity(0.2) : CoffeeTheme.cardElevated,
                            in: Capsule()
                        )
                        .foregroundStyle(copiedTarget == "all" ? CoffeeTheme.successGreen : CoffeeTheme.cremaLight)
                }
            }

            // Title block with dedicated 1-tap copy
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("标题")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.mutedText)
                    Text("\(titleCount)/20 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(titleCount > 20 ? CoffeeTheme.warningAmber : CoffeeTheme.mutedText.opacity(0.8))
                    Spacer()
                    Button {
                        copyText(
                            editableTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            targetKey: "title",
                            status: "已复制小红书标题，可直接粘贴到标题栏"
                        )
                    } label: {
                        Label(copiedTarget == "title" ? "已复制标题" : "复制标题", systemImage: copiedTarget == "title" ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                copiedTarget == "title" ? CoffeeTheme.successGreen.opacity(0.22) : CoffeeTheme.cremaAccent.opacity(0.2),
                                in: Capsule()
                            )
                            .foregroundStyle(copiedTarget == "title" ? CoffeeTheme.successGreen : CoffeeTheme.cremaAccent)
                    }
                }

                TextField("小红书标题（建议 20 字内）", text: $editableTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.warmText)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CoffeeTheme.cardElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                            )
                    )
            }

            // Body block with dedicated 1-tap copy
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("正文与话题标签")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.mutedText)
                    Spacer()
                    Button {
                        copyText(
                            editableBody.trimmingCharacters(in: .whitespacesAndNewlines),
                            targetKey: "body",
                            status: "已复制小红书正文，可直接粘贴到正文栏"
                        )
                    } label: {
                        Label(copiedTarget == "body" ? "已复制正文" : "复制正文", systemImage: copiedTarget == "body" ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                copiedTarget == "body" ? CoffeeTheme.successGreen.opacity(0.22) : CoffeeTheme.cremaAccent.opacity(0.2),
                                in: Capsule()
                            )
                            .foregroundStyle(copiedTarget == "body" ? CoffeeTheme.successGreen : CoffeeTheme.cremaAccent)
                    }
                }

                TextEditor(text: $editableBody)
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CoffeeTheme.cardElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                            )
                    )
            }
        }
        .padding(14)
        .background(CoffeeTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func copyText(_ text: String, targetKey: String, status: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        exportStatus = status
        copiedTarget = targetKey
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if copiedTarget == targetKey {
                    copiedTarget = nil
                }
            }
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            if let status = exportStatus {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(status)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(CoffeeTheme.successGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let err = exportError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(CoffeeTheme.dangerRed)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            #if canImport(UIKit)
            Button {
                Task { await publishToXiaohongshuOneTap() }
            } label: {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(
                        isExporting
                            ? (dynamicClipCount > 0 ? "正在渲染图组并裁切 \(dynamicClipCount) 段特写视频..." : "正在存图并跳转小红书...")
                            : (isCurrentSelectionAlreadySaved
                                ? "已存素材 · 直接跳转小红书发布（\(exportAssetSummaryText)）"
                                : "一键发小红书（存 \(exportAssetSummaryText) + 复制文案）")
                    )
                    .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color(red: 0.92, green: 0.22, blue: 0.28),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(.white)
            }
            .disabled(isExporting || totalSelectedItems == 0)

            HStack(spacing: 10) {
                Button {
                    Task { _ = await exportAllToPhotosAndCopy() }
                } label: {
                    Label("仅存相册 + 复制", systemImage: "square.and.arrow.down.on.square")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .disabled(isExporting || totalSelectedItems == 0)

                Button {
                    Task { await prepareAndOpenSystemShare() }
                } label: {
                    Label("系统多图分享", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .disabled(isExporting || totalSelectedItems == 0)
            }
            #endif
        }
    }

    // MARK: - Helpers & Export Pipeline

    private func splitInitialCopy() {
        let raw = record.xiaohongshuCopy.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw.components(separatedBy: .newlines)
        if let first = lines.first, !first.isEmpty {
            editableTitle = first
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            editableBody = rest
        } else {
            editableTitle = "☕️ 今日咖啡萃取日记"
            editableBody = raw
        }
    }

    private var combinedCopy: String {
        [editableTitle.trimmingCharacters(in: .whitespacesAndNewlines),
         editableBody.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func copyFullTextToPasteboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = combinedCopy
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    private func renderSelectedImages() -> [UIImage] {
        var images: [UIImage] = []
        let targetSize = CGSize(width: 360, height: 480) // 3:4 at scale 3.0 -> 1080x1440 px

        if includeCoverCard {
            let cover = XiaohongshuCoverPosterView(
                record: record,
                keyframes: keptKeyframes,
                customTitles: customStageTitles
            )
            .frame(width: targetSize.width, height: targetSize.height)
            let renderer = ImageRenderer(content: cover)
            renderer.scale = 3.0
            if let img = renderer.uiImage {
                images.append(img)
            }
        }

        for (idx, kf) in keptKeyframes.enumerated() {
            let card = XiaohongshuKeyframeCardView(
                record: record,
                keyframe: kf,
                index: idx + 1,
                overrideTitle: customStageTitles[kf.id]
            )
            .frame(width: targetSize.width, height: targetSize.height)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3.0
            if let img = renderer.uiImage {
                images.append(img)
            }
        }
        return images
    }

    private func publishToXiaohongshuOneTap() async {
        copyFullTextToPasteboard()
        if !isCurrentSelectionAlreadySaved {
            let saved = await exportAllToPhotosAndCopy()
            guard saved else { return }
        }
        openXiaohongshuApp()
    }

    @discardableResult
    private func exportAllToPhotosAndCopy() async -> Bool {
        isExporting = true
        exportError = nil
        exportStatus = nil
        defer { isExporting = false }

        copyFullTextToPasteboard()

        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            exportError = "请在系统「设置 → 隐私 → 照片」允许保存图片到相册（文案已复制）。"
            return false
        }

        let images = renderSelectedImages()
        var clipURLs: [URL] = []
        if !keptClipKeyframes.isEmpty, let videoPath = resolvedSourceVideoPath {
            clipURLs = await AppleOnDeviceMediaRecognizer.exportDynamicCloseUpClips(
                videoURL: URL(fileURLWithPath: videoPath),
                keyframes: keptClipKeyframes,
                maxClips: keptClipKeyframes.count,
                clipDurationS: 2.5
            )
            if clipURLs.isEmpty && !images.isEmpty {
                exportError = "未能从原视频裁切出 2.5 秒特写视频（已继续保存 3:4 精排图）。"
            }
        }

        guard !images.isEmpty || !clipURLs.isEmpty else {
            exportError = "未能导出素材，请至少保留 1 张卡片或 1 段实况视频。"
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                for clipURL in clipURLs {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clipURL)
                }
            }
            for clipURL in clipURLs {
                try? FileManager.default.removeItem(at: clipURL)
            }
            lastSavedSelectionSignature = currentSelectionSignature
            let clipNote = clipURLs.isEmpty ? "" : " + \(clipURLs.count) 段 2.5 秒特写实况"
            exportStatus = "已保存 \(images.count) 张 3:4 精排图\(clipNote)到相册，并复制小红书文案。"
            return true
        } catch {
            exportError = "保存到相册失败：\(error.localizedDescription)"
            return false
        }
    }

    private func prepareAndOpenSystemShare() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        copyFullTextToPasteboard()
        let images = renderSelectedImages()
        var items: [Any] = images
        if !keptClipKeyframes.isEmpty, let videoPath = resolvedSourceVideoPath {
            let clipURLs = await AppleOnDeviceMediaRecognizer.exportDynamicCloseUpClips(
                videoURL: URL(fileURLWithPath: videoPath),
                keyframes: keptClipKeyframes,
                maxClips: keptClipKeyframes.count,
                clipDurationS: 2.5
            )
            items.append(contentsOf: clipURLs)
        }
        items.append(combinedCopy)
        shareItems = items
        showSystemShareSheet = true
    }

    private func openXiaohongshuApp() {
        copyFullTextToPasteboard()
        let candidates = [
            "xhsdiscover://post",
            "xhsdiscover://post_note",
            "xhsdiscover://",
        ].compactMap(URL.init(string:))

        openFirstAvailableXiaohongshuURL(candidates, index: 0)
    }

    private func openFirstAvailableXiaohongshuURL(_ urls: [URL], index: Int) {
        guard index < urls.count else {
            exportStatus = "已保存 \(totalSelectedCards) 张图并复制文案，请手动打开小红书勾选相册前 \(totalSelectedCards) 张发布。"
            return
        }
        let target = urls[index]
        guard UIApplication.shared.canOpenURL(target) else {
            openFirstAvailableXiaohongshuURL(urls, index: index + 1)
            return
        }
        UIApplication.shared.open(target, options: [:]) { success in
            if success {
                Task { @MainActor in
                    exportStatus = "已保存 \(totalSelectedCards) 张图、复制文案并跳转小红书发布页，勾选相册最前面图组即可发布！"
                }
            } else {
                Task { @MainActor in
                    openFirstAvailableXiaohongshuURL(urls, index: index + 1)
                }
            }
        }
    }
    #endif
}

// MARK: - 3:4 Cover Poster View (1080x1440 at 3x)

private struct XiaohongshuCoverPosterView: View {
    let record: CoffeeRecord
    let keyframes: [KeyframeObservation]
    var customTitles: [String: String] = [:]

    private var heroKeyframe: KeyframeObservation? {
        keyframes.max(by: { $0.sharpnessScore < $1.sharpnessScore }) ?? keyframes.last
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.075, blue: 0.055), Color(red: 0.18, green: 0.12, blue: 0.085)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                // Header ribbon
                HStack {
                    Text(record.recordType == .equipmentProfile ? "BREWLENS 萃镜 · 器具档案" : "BREWLENS 萃镜 · 今日萃取")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                    Spacer()
                    Text(String(record.createdAt.prefix(10)))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(CoffeeTheme.mutedText)
                }

                // Hero photo or minimalist crema emblem
                if let hero = heroKeyframe, let img = loadLocalImage(hero.imagePath) {
                    ZStack(alignment: .bottomLeading) {
                        img
                            .resizable()
                            .scaledToFill()
                            .frame(height: 175)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.72)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.beanName ?? "今日精选咖啡")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(subtitleLine)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CoffeeTheme.cremaLight)
                                .lineLimit(1)
                        }
                        .padding(10)
                    }
                    .frame(height: 175)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.beanName ?? "今日精选咖啡")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitleLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CoffeeTheme.cremaLight)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CoffeeTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Core metrics or equipment pills
                if record.recordType == .equipmentProfile {
                    let items = Array(record.equipmentItems.prefix(4))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.category)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(CoffeeTheme.cremaAccent)
                                Text(item.name)
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        metricBadge("粉液比", value: record.brewRatio ?? "--", sub: "\(fmt(record.beanWeightG))g→\(fmt(record.yieldG))g")
                        metricBadge("研磨刻度", value: record.grindSetting ?? "--", sub: record.grinderModel ?? "磨豆机")
                        metricBadge("时间/压力", value: safeSecLabel(record.extractionTimeS), sub: "\(fmt(record.pressureBar)) bar")
                    }
                }

                // Mini keyframe close-up strip (coffee machine / beans / dial / cup)
                if keyframes.count >= 2 {
                    HStack(spacing: 6) {
                        ForEach(Array(keyframes.prefix(4).enumerated()), id: \.element.id) { idx, kf in
                            if let thumb = loadLocalImage(kf.imagePath) {
                                ZStack(alignment: .bottomLeading) {
                                    thumb
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 62)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                    Text(customTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile))
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.62), in: Capsule())
                                        .padding(4)
                                }
                            }
                        }
                    }
                }

                // Flavor tags
                if !record.flavorNotes.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(record.flavorNotes.prefix(4)), id: \.self) { note in
                            Text("✦ \(note)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(CoffeeTheme.cremaLight)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(CoffeeTheme.cremaAccent.opacity(0.18), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Footer diagnosis quote
                Text(record.extractionDiagnosis)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(14)
        }
    }

    private var subtitleLine: String {
        if record.recordType == .equipmentProfile {
            return "\(record.grinderModel ?? "居家咖啡角") · 共收录 \(record.equipmentItems.count) 项器具"
        }
        return [record.brewMethod, record.beanRoast].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func metricBadge(_ title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(CoffeeTheme.cremaAccent)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 8))
                .foregroundStyle(CoffeeTheme.mutedText)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func safeSecLabel(_ val: Double?) -> String {
        guard let val, val.isFinite, val >= 0 else { return "--" }
        return "\(Int(min(val, 100_000.0)))s"
    }

    private func fmt(_ val: Double?) -> String {
        guard let val, val.isFinite, abs(val) <= 1_000_000 else { return "--" }
        return val.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(val))" : String(format: "%.1f", val)
    }
}

// MARK: - 3:4 Per-Keyframe Close-Up Card (1080x1440 at 3x)

private struct XiaohongshuKeyframeCardView: View {
    let record: CoffeeRecord
    let keyframe: KeyframeObservation
    let index: Int
    var overrideTitle: String? = nil

    private var resolvedShortTitle: String {
        overrideTitle ?? shortStageTitle(keyframe, isEquipment: record.recordType == .equipmentProfile)
    }

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.07, blue: 0.05)

            if let img = loadLocalImage(keyframe.imagePath) {
                img
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            // Top & bottom subtle editorial vignettes
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 82)
                Spacer()
                LinearGradient(colors: [.clear, Color.black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 128)
            }

            VStack(alignment: .leading) {
                // Top-left index & stage badge
                HStack {
                    Text(String(format: "%02d · %@", index, resolvedShortTitle))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Text(String(format: "t=%.1fs", keyframe.timestampS))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                }

                Spacer()

                // Bottom caption bar with exact stage parameter
                VStack(alignment: .leading, spacing: 4) {
                    Text(stageHeadline)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(stageMetricLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                        .lineLimit(2)

                    HStack {
                        Text("BREWLENS 萃镜 · \(record.beanName ?? "咖啡日记")")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
        }
    }

    private var stageHeadline: String {
        if let overrideTitle, !overrideTitle.isEmpty {
            return overrideTitle
        }
        if record.recordType == .equipmentProfile {
            return keyframe.presetBadge ?? keyframe.stage
        }
        if let detectedWeight = keyframe.detectedFields["bean_weight_g"] {
            return "称重读数 \(detectedWeight)"
        }
        switch keyframe.stageKey {
        case "scale_dose": return "称重豆量与咖啡豆特写"
        case "grinding", "grinder_dial": return "磨豆出粉与研磨刻度"
        case "dose_weigh": return "接粉称重与出粉量核对"
        case "wdt_distribute": return "布粉针打散结块特写"
        case "leveler_flatten": return "布粉器旋转压平特写"
        case "tamping": return "压粉锤恒力压粉特写"
        case "pressure_crema": return "咖啡机萃取与油脂流态"
        case "yield_timer": return "出杯液重与成品特写"
        case "bean_bag": return "咖啡豆特写"
        case "scene_highlight": return "咖啡制作瞬间特写"
        default: return keyframe.stage
        }
    }

    private var stageMetricLine: String {
        if record.recordType == .equipmentProfile {
            let names = record.equipmentItems.prefix(3).map(\.name).joined(separator: " · ")
            return names.isEmpty ? "居家咖啡角常驻器具特写" : names
        }
        switch keyframe.stageKey {
        case "scale_dose", "dose_weigh":
            let dose = keyframe.detectedFields["bean_weight_g"]
                ?? record.beanWeightG.map { String(format: "%.1fg 粉量", $0) }
                ?? "精准称重"
            return "\(dose) · \(record.beanName ?? "今日单品豆")"
        case "grinding", "grinder_dial":
            return "\(record.grinderModel ?? "磨豆机") · \(record.grindSetting ?? "研磨出粉")"
        case "wdt_distribute":
            return "WDT 布粉针充分打散结块，减少通道效应"
        case "leveler_flatten":
            return "布粉器水平找平，确保粉层密度均匀"
        case "tamping":
            return "垂直恒力压实粉饼，准备上柄萃取"
        case "pressure_crema":
            let bar = record.pressureBar.map { String(format: "%.1f bar", $0) } ?? "稳定泵压"
            let temp = record.waterTempC.map { String(format: " · %.0f°C", $0) } ?? ""
            return "\(record.brewMethod ?? "意式浓缩") · \(bar)\(temp)"
        case "yield_timer":
            let y = record.yieldG.flatMap { $0.isFinite ? String(format: "%.1fg 出液", $0) : nil } ?? "黄金出杯"
            let t = record.extractionTimeS.flatMap { ($0.isFinite && $0 >= 0) ? " · \(Int(min($0, 100_000.0)))s" : nil } ?? ""
            let r = record.brewRatio.map { " · \($0)" } ?? ""
            return "\(y)\(t)\(r)"
        case "bean_bag":
            return [record.beanName, record.beanRoast].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "scene_highlight":
            let summary = [record.beanName, record.brewRatio].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return summary.isEmpty ? "实拍冲煮细节特写" : summary
        default:
            return keyframe.visualDescription
        }
    }
}

// MARK: - Shared Image & Stage Helpers

private func shortStageTitle(_ kf: KeyframeObservation, isEquipment: Bool) -> String {
    if isEquipment {
        return kf.presetBadge ?? "器具特写"
    }
    if kf.detectedFields["bean_weight_g"] != nil && kf.stageKey != "scale_dose" && kf.stageKey != "dose_weigh" {
        return "称重豆量"
    }
    switch kf.stageKey {
    case "scale_dose": return "称重豆量"
    case "grinding", "grinder_dial": return "磨豆出粉"
    case "dose_weigh": return "接粉称重"
    case "wdt_distribute": return "布粉针打散"
    case "leveler_flatten": return "布粉器压平"
    case "tamping": return "压粉锤压粉"
    case "pressure_crema": return "咖啡机萃取"
    case "yield_timer": return "成品出杯"
    case "bean_bag": return "咖啡豆特写"
    case "scene_highlight": return "制作特写"
    default: return "制作特写"
    }
}

private func loadLocalImage(_ path: String?) -> Image? {
    guard let resolved = SandboxPathResolver.resolveLocalFilePath(path) else { return nil }
    #if canImport(UIKit)
    guard let uiImage = UIImage(contentsOfFile: resolved) else { return nil }
    return Image(uiImage: uiImage)
    #else
    return nil
    #endif
}

#if canImport(UIKit)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Inline 2.5s Live Clip Card & Full-Screen Paged Lightbox

private struct XiaohongshuClipThumbnailCard: View {
    let keyframe: KeyframeObservation
    let stageTitle: String
    let clipNumber: Int

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.07, blue: 0.05)

            if let img = loadLocalImage(keyframe.imagePath) {
                img
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            Color.black.opacity(0.24)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.55))

            VStack(alignment: .leading) {
                HStack {
                    Label("LIVE 2.5s", systemImage: "livephoto.play")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(CoffeeTheme.espressoBg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(CoffeeTheme.warningAmber, in: Capsule())
                    Spacer()
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("特写实况 \(clipNumber) · \(stageTitle)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(String(format: "t=%.1fs 附近 2.5 秒高清片段 · 点击预览", keyframe.timestampS))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(10)
        }
    }
}

private struct XiaohongshuClipLoopPlayer: View {
    let videoURL: URL
    let centerTimestampS: Double
    let durationS: Double

    @State private var player: AVPlayer?
    @State private var loopObserver: Any?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    .disabled(false)
            } else {
                ProgressView()
                    .tint(CoffeeTheme.cremaAccent)
            }
        }
        .onAppear {
            startLoopingPreview()
        }
        .onDisappear {
            stopPreview()
        }
    }

    private func startLoopingPreview() {
        stopPreview()
        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        Task {
            let safeCenter = (centerTimestampS.isFinite && centerTimestampS >= 0) ? centerTimestampS : 0.0
            let safeReqDur = (durationS.isFinite && durationS >= 0.8) ? min(durationS, 15.0) : 2.5
            let loadedDur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let safeTotal = (loadedDur.isFinite && loadedDur > 1.0) ? loadedDur : max(1.0, safeCenter + safeReqDur)
            let safeLen = min(safeReqDur, max(0.8, safeTotal))
            let startSec = min(max(0.0, safeCenter - safeLen * 0.4), max(0.0, safeTotal - safeLen))
            let startTime = CMTime(seconds: startSec, preferredTimescale: 600)
            let endTime = CMTime(seconds: startSec + safeLen, preferredTimescale: 600)

            await MainActor.run {
                avPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                avPlayer.play()
                let observer = avPlayer.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: endTime)],
                    queue: .main
                ) { [weak avPlayer] in
                    avPlayer?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    avPlayer?.play()
                }
                self.loopObserver = observer
            }
        }
    }

    private func stopPreview() {
        if let observer = loopObserver, let player {
            player.removeTimeObserver(observer)
        }
        loopObserver = nil
        player?.pause()
        player = nil
    }
}

private struct XiaohongshuCardPreviewOverlay: View {
    let record: CoffeeRecord
    let sourceVideoURL: URL?
    @Binding var includeCoverCard: Bool
    let keptKeyframes: [KeyframeObservation]
    @Binding var removedKeyframeIDs: Set<String>
    let keptClipKeyframes: [KeyframeObservation]
    @Binding var removedClipKeyframeIDs: Set<String>
    let customStageTitles: [String: String]
    let onClose: () -> Void

    @State private var currentIndex: Int

    init(
        record: CoffeeRecord,
        sourceVideoURL: URL?,
        includeCoverCard: Binding<Bool>,
        keptKeyframes: [KeyframeObservation],
        removedKeyframeIDs: Binding<Set<String>>,
        keptClipKeyframes: [KeyframeObservation],
        removedClipKeyframeIDs: Binding<Set<String>>,
        customStageTitles: [String: String],
        initialIndex: Int,
        onClose: @escaping () -> Void
    ) {
        self.record = record
        self.sourceVideoURL = sourceVideoURL
        self._includeCoverCard = includeCoverCard
        self.keptKeyframes = keptKeyframes
        self._removedKeyframeIDs = removedKeyframeIDs
        self.keptClipKeyframes = keptClipKeyframes
        self._removedClipKeyframeIDs = removedClipKeyframeIDs
        self.customStageTitles = customStageTitles
        self.onClose = onClose
        _currentIndex = State(initialValue: initialIndex)
    }

    private enum PreviewCard: Identifiable {
        case cover
        case keyframe(index: Int, frame: KeyframeObservation)
        case videoClip(index: Int, frame: KeyframeObservation)

        var id: String {
            switch self {
            case .cover: return "cover"
            case .keyframe(_, let frame): return "kf-\(frame.id)"
            case .videoClip(_, let frame): return "clip-\(frame.id)"
            }
        }
    }

    private var cards: [PreviewCard] {
        var result: [PreviewCard] = []
        if includeCoverCard {
            result.append(.cover)
        }
        for (idx, kf) in keptKeyframes.enumerated() {
            result.append(.keyframe(index: idx + 1, frame: kf))
        }
        for (idx, kf) in keptClipKeyframes.enumerated() {
            result.append(.videoClip(index: idx + 1, frame: kf))
        }
        return result
    }

    private var safeIndex: Int {
        guard !cards.isEmpty else { return 0 }
        return min(max(0, currentIndex), cards.count - 1)
    }

    private var currentTitle: String {
        guard !cards.isEmpty else { return "" }
        switch cards[safeIndex] {
        case .cover:
            return "封面总览"
        case .keyframe(_, let kf):
            return customStageTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile)
        case .videoClip(let idx, let kf):
            let name = customStageTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile)
            return "实况 \(idx) · \(name) (2.5s)"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    if !cards.isEmpty {
                        Text("第 \(safeIndex + 1) / \(cards.count) 项 · \(currentTitle)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("关闭预览")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                if cards.isEmpty {
                    Spacer()
                    Text("已无选中素材")
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                } else {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                            GeometryReader { geo in
                                let maxW = geo.size.width - 28
                                let maxH = geo.size.height - 16
                                let fittedW = min(maxW, maxH * 0.75)
                                let fittedH = fittedW * (4.0 / 3.0)

                                Group {
                                    switch card {
                                    case .cover:
                                        XiaohongshuCoverPosterView(
                                            record: record,
                                            keyframes: keptKeyframes,
                                            customTitles: customStageTitles
                                        )
                                        .frame(width: 360, height: 480)
                                        .scaleEffect(fittedW / 360.0)
                                        .frame(width: fittedW, height: fittedH)
                                    case .keyframe(let kfIdx, let kf):
                                        XiaohongshuKeyframeCardView(
                                            record: record,
                                            keyframe: kf,
                                            index: kfIdx,
                                            overrideTitle: customStageTitles[kf.id]
                                        )
                                        .frame(width: 360, height: 480)
                                        .scaleEffect(fittedW / 360.0)
                                        .frame(width: fittedW, height: fittedH)
                                    case .videoClip(_, let kf):
                                        if let videoURL = sourceVideoURL {
                                            XiaohongshuClipLoopPlayer(
                                                videoURL: videoURL,
                                                centerTimestampS: kf.timestampS,
                                                durationS: 2.5
                                            )
                                            .frame(width: fittedW, height: fittedH)
                                        } else {
                                            XiaohongshuClipThumbnailCard(
                                                keyframe: kf,
                                                stageTitle: customStageTitles[kf.id] ?? shortStageTitle(kf, isEquipment: record.recordType == .equipmentProfile),
                                                clipNumber: idx + 1
                                            )
                                            .frame(width: fittedW, height: fittedH)
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(CoffeeTheme.cremaAccent.opacity(0.55), lineWidth: 1)
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))

                    HStack {
                        Button(role: .destructive) {
                            deleteCurrentCard()
                        } label: {
                            Label("删除当前项", systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(CoffeeTheme.dangerRed.opacity(0.22), in: Capsule())
                                .foregroundStyle(CoffeeTheme.dangerRed)
                        }

                        Spacer()

                        Button("完成预览") {
                            onClose()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(CoffeeTheme.cremaAccent, in: Capsule())
                        .foregroundStyle(CoffeeTheme.espressoBg)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func deleteCurrentCard() {
        guard !cards.isEmpty else { return }
        let idx = safeIndex
        switch cards[idx] {
        case .cover:
            includeCoverCard = false
        case .keyframe(_, let kf):
            removedKeyframeIDs.insert(kf.id)
        case .videoClip(_, let kf):
            removedClipKeyframeIDs.insert(kf.id)
        }
        let remaining = cards.count - 1
        if remaining <= 0 {
            onClose()
        } else if currentIndex >= remaining {
            currentIndex = remaining - 1
        }
    }
}

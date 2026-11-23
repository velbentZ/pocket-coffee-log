import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PocketCoffeeCore
#if canImport(UIKit)
import UIKit
#endif

struct MovieTransferable: Transferable {
    let url: URL

    private static func copyImportedFile(_ received: ReceivedTransferredFile, fallbackExt: String) throws -> MovieTransferable {
        if let vals = try? received.file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            guard vals.isRegularFile == true, vals.isSymbolicLink != true else {
                throw CocoaError(.fileReadNoPermission)
            }
            if let size = vals.fileSize, Int64(size) > 1_073_741_824 {
                throw CocoaError(.fileReadTooLarge)
            }
        }
        let tempDir = FileManager.default.temporaryDirectory
        let ext = DeepLinkValidator.sanitizeMediaExtension(received.file.pathExtension, fallback: fallbackExt)
        let dest = tempDir.appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: received.file, to: dest)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dest.path
        )
        #endif
        return MovieTransferable(url: dest)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            try copyImportedFile(received, fallbackExt: "mov")
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            try copyImportedFile(received, fallbackExt: "mp4")
        }
        FileRepresentation(importedContentType: .movie) { received in
            try copyImportedFile(received, fallbackExt: "mov")
        }
        FileRepresentation(importedContentType: .video) { received in
            try copyImportedFile(received, fallbackExt: "mov")
        }
        FileRepresentation(importedContentType: .audiovisualContent) { received in
            try copyImportedFile(received, fallbackExt: "mov")
        }
    }
}

struct IngestTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingMedia: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var selectedMediaURL: URL?
    @State private var selectedMediaLabel: String = ""
    @State private var selectedMediaMeta: String = ""
    @State private var detectedCaptureDevice: String?
    @State private var spokenNotes: String = ""

    @State private var recordIntent: RecordIntent = .auto
    @State private var showShortcutsGuide: Bool = false

    private var inferredSourceType: SourceType {
        if let url = selectedMediaURL {
            if isAudioFile(url) { return .audioNote }
            #if canImport(UIKit)
            if UIDevice.current.userInterfaceIdiom == .pad { return .ipad }
            #endif
            return .iphone
        }
        return .manualText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CoffeeTabHeader(
                    title: "拍摄与导入",
                    subtitle: "100% 端侧离线识别 · 视频 / 语音 / 文字",
                    subtitleIcon: "sparkles",
                    subtitleIconColor: CoffeeTheme.cremaAccent
                ) {
                    Button {
                        showShortcutsGuide = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.badge.automatic")
                                .font(.caption.weight(.bold))
                            Text("自动化")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CoffeeTheme.cardElevated, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(CoffeeTheme.cremaAccent.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 16) {
                        mediaSourceSection
                        configPickersSection
                        notesInputSection
                        actionButtonsSection

                        if let preview = viewModel.lastRecognitionPreview {
                            recognitionPreviewSection(preview)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showShortcutsGuide) {
                ShortcutsGuideSheet()
                    .environmentObject(viewModel)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie, .video, .audio, .audiovisualContent],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let first = urls.first, let imported = viewModel.importMediaFile(from: first) {
                        selectedMediaURL = imported
                        selectedMediaLabel = first.lastPathComponent
                        selectedMediaMeta = describeMediaFile(imported)
                        detectedCaptureDevice = nil
                        Task {
                            if let dev = await AppleOnDeviceMediaRecognizer.extractCaptureDevice(from: imported) {
                                detectedCaptureDevice = dev
                                selectedMediaMeta = "\(describeMediaFile(imported)) · 拍自 \(dev)"
                            }
                        }
                        viewModel.showStatus("已导入媒体：\(first.lastPathComponent)")
                    } else {
                        viewModel.showError("无法读取所选文件，请重试")
                    }
                case .failure(let error):
                    viewModel.showError("选择文件失败：\(error.localizedDescription)")
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    isImportingMedia = true
                    viewModel.clearMessages()
                    defer {
                        isImportingMedia = false
                        selectedPhotoItem = nil
                    }
                    do {
                        if let movie = try await newItem.loadTransferable(type: MovieTransferable.self) {
                            defer { try? FileManager.default.removeItem(at: movie.url) }
                            if let copied = viewModel.importMediaFile(from: movie.url) {
                                selectedMediaURL = copied
                                selectedMediaLabel = "相册视频已就绪"
                                let dev = await AppleOnDeviceMediaRecognizer.extractCaptureDevice(from: copied)
                                detectedCaptureDevice = dev
                                let baseMeta = describeMediaFile(copied)
                                selectedMediaMeta = dev.map { "\(baseMeta) · 拍自 \($0)" } ?? baseMeta
                                viewModel.showStatus("已导入相册视频（\(selectedMediaMeta)），点击下方即可识别生成")
                                return
                            }
                        }
                        if let rawData = try await newItem.loadTransferable(type: Data.self),
                           !rawData.isEmpty,
                           Int64(rawData.count) <= 1_073_741_824 {
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("picked-data-\(UUID().uuidString).mov")
                            #if os(iOS)
                            try rawData.write(to: tempURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                            #else
                            try rawData.write(to: tempURL, options: .atomic)
                            #endif
                            defer { try? FileManager.default.removeItem(at: tempURL) }
                            if let copied = viewModel.importMediaFile(from: tempURL, suggestedExtension: "mov") {
                                selectedMediaURL = copied
                                selectedMediaLabel = "相册视频已就绪"
                                let dev = await AppleOnDeviceMediaRecognizer.extractCaptureDevice(from: copied)
                                detectedCaptureDevice = dev
                                let baseMeta = describeMediaFile(copied)
                                selectedMediaMeta = dev.map { "\(baseMeta) · 拍自 \($0)" } ?? baseMeta
                                viewModel.showStatus("已导入相册视频（\(selectedMediaMeta)），点击下方即可识别生成")
                                return
                            }
                        }
                        viewModel.showError("未能读取该相册视频（若视频存储在 iCloud，请先在相册播放下载到本地后重试）")
                    } catch {
                        viewModel.showError("读取相册视频失败：\(error.localizedDescription)")
                    }
                }
            }
            .onChange(of: viewModel.recordedAudioURL) { _, newURL in
                if let newURL, !viewModel.isRecordingAudio {
                    selectedMediaURL = newURL
                    selectedMediaLabel = "端侧录音 (\(String(format: "%.1f", viewModel.recordingDurationS))s)"
                    selectedMediaMeta = describeMediaFile(newURL)
                }
            }
        }
    }

    private var mediaSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择或录制素材")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CoffeeTheme.cremaLight)

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .videos,
                    preferredItemEncoding: .current
                ) {
                    sourceButtonTile(title: "相册视频", subtitle: "Photos", icon: "photo.on.rectangle.angled")
                }

                Button {
                    showFileImporter = true
                } label: {
                    sourceButtonTile(title: "导入文件", subtitle: "视频/语音", icon: "folder.badge.plus")
                }

                Button {
                    viewModel.toggleVoiceRecording()
                } label: {
                    sourceButtonTile(
                        title: viewModel.isRecordingAudio ? "停止录音" : "语音口述",
                        subtitle: viewModel.isRecordingAudio ? formatDuration(viewModel.recordingDurationS) : "即时录音",
                        icon: viewModel.isRecordingAudio ? "stop.circle.fill" : "mic.fill",
                        isActive: viewModel.isRecordingAudio
                    )
                }
            }

            if isImportingMedia {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(CoffeeTheme.cremaAccent)
                    Text("正在从相册导入视频（如在 iCloud 中将自动下载）...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CoffeeTheme.cardElevated)
                )
            }

            if let mediaURL = selectedMediaURL {
                HStack(spacing: 10) {
                    Image(systemName: isAudioFile(mediaURL) ? "waveform.circle.fill" : "film.fill")
                        .font(.title3)
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedMediaLabel.isEmpty ? mediaURL.lastPathComponent : selectedMediaLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CoffeeTheme.warmText)
                            .lineLimit(1)
                        Text(selectedMediaMeta.isEmpty ? mediaURL.lastPathComponent : selectedMediaMeta)
                            .font(.caption2)
                            .foregroundStyle(CoffeeTheme.mutedText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        selectedMediaURL = nil
                        selectedMediaLabel = ""
                        selectedMediaMeta = ""
                        selectedPhotoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(CoffeeTheme.mutedText)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CoffeeTheme.cardElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CoffeeTheme.cremaAccent.opacity(0.4), lineWidth: 1)
                        )
                )
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var configPickersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("识别意图")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.mutedText)
                Spacer()
                if let device = detectedCaptureDevice {
                    Label("自动识别：\(device)", systemImage: "camera.aperture")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                }
            }
            Picker("识别意图", selection: $recordIntent) {
                Text("自动判断").tag(RecordIntent.auto)
                Text("制作报告").tag(RecordIntent.brewReport)
                Text("设备建档").tag(RecordIntent.equipmentProfile)
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var notesInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("补充口述 / 文字笔记")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                if !spokenNotes.isEmpty {
                    Button("清空") { spokenNotes = "" }
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
            }

            ZStack(alignment: .topLeading) {
                if spokenNotes.isEmpty {
                    Text("例如：今天用耶加雪菲18克，Niche Zero刻度15，93度，9bar萃取28秒出液36克；或介绍你的咖啡机、磨豆机与配件...")
                        .font(.subheadline)
                        .foregroundStyle(CoffeeTheme.mutedText.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $spokenNotes)
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 88)
                    .padding(4)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CoffeeTheme.cardElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .padding(14)
        .background(cardBackground)
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            if viewModel.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(CoffeeTheme.cremaAccent)
                    Text(viewModel.busyLabel.isEmpty ? "正在处理..." : viewModel.busyLabel)
                        .font(.subheadline)
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(cardBackground)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.runRecognitionPreview(
                            mediaURL: selectedMediaURL,
                            spokenTranscript: spokenNotes,
                            sourceType: inferredSourceType
                        )
                    }
                } label: {
                    Label("仅识别预览", systemImage: "eye.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CoffeeTheme.cardElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(CoffeeTheme.cremaAccent.opacity(0.7), lineWidth: 1)
                                )
                        )
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .disabled(viewModel.isBusy || viewModel.isRecordingAudio)

                Button {
                    Task {
                        await viewModel.runOneClickIngest(
                            mediaURL: selectedMediaURL,
                            spokenTranscript: spokenNotes,
                            sourceType: inferredSourceType,
                            recordIntent: recordIntent
                        )
                    }
                } label: {
                    Label("一键识别并生成", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CoffeeTheme.cremaAccent)
                        )
                        .foregroundStyle(CoffeeTheme.espressoBg)
                }
                .disabled(viewModel.isBusy || viewModel.isRecordingAudio)
            }
        }
    }

    private func recognitionPreviewSection(_ preview: RecognitionOutput) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("端侧识别预览", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                Text(preview.mediaKind.rawValue.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CoffeeTheme.cardElevated, in: Capsule())
                    .foregroundStyle(CoffeeTheme.cremaAccent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("可编辑转写文本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.mutedText)
                TextEditor(text: $viewModel.editableTranscript)
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CoffeeTheme.cardElevated)
                    )
            }

            let fields = viewModel.editableVisualFields.asDisplayDictionary
            if !fields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("视觉 OCR 提取字段")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.mutedText)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(fields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack {
                                Text(ocrFieldLabel(key))
                                    .font(.caption)
                                    .foregroundStyle(CoffeeTheme.mutedText)
                                Spacer()
                                Text(value)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(CoffeeTheme.warmText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }

            if !preview.keyframes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("提取关键帧（\(preview.keyframes.count)）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.mutedText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(preview.keyframes) { frame in
                                keyframeCard(frame)
                            }
                        }
                    }
                }
            }

            Button {
                Task {
                    await viewModel.generateFromPreview(
                        sourceType: inferredSourceType,
                        recordIntent: recordIntent
                    )
                }
            } label: {
                Label("基于此预览生成报告 / 建档", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(CoffeeTheme.espressoBg)
            }
            .disabled(viewModel.isBusy)
        }
        .padding(14)
        .background(cardBackground)
    }

    private func keyframeCard(_ frame: KeyframeObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                #if canImport(UIKit)
                if let path = SandboxPathResolver.resolveLocalFilePath(frame.imagePath), let uiImage = UIImage(contentsOfFile: path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 84)
                        .clipped()
                } else {
                    placeholderKeyframeThumb
                }
                #else
                placeholderKeyframeThumb
                #endif

                Text(String(format: "%.1fs · %d%%", frame.timestampS, frame.percentage))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(frame.stage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CoffeeTheme.warmText)
                .lineLimit(1)

            if !frame.ocrTexts.isEmpty {
                Text(frame.ocrTexts.prefix(2).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.mutedText)
                    .lineLimit(2)
            } else if !frame.visualDescription.isEmpty {
                Text(frame.visualDescription)
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.mutedText)
                    .lineLimit(2)
            }
        }
        .frame(width: 140)
        .padding(8)
        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderKeyframeThumb: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .frame(width: 140, height: 84)
            .overlay(
                Image(systemName: "photo.fill")
                    .foregroundStyle(CoffeeTheme.mutedText.opacity(0.5))
            )
    }

    private func sourceButtonTile(title: String, subtitle: String, icon: String, isActive: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isActive ? CoffeeTheme.dangerRed : CoffeeTheme.cremaAccent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CoffeeTheme.warmText)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(isActive ? CoffeeTheme.dangerRed : CoffeeTheme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? CoffeeTheme.dangerRed.opacity(0.16) : CoffeeTheme.cardElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? CoffeeTheme.dangerRed.opacity(0.7) : CoffeeTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func describeMediaFile(_ url: URL) -> String {
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return "\(url.pathExtension.uppercased()) · \(sizeStr)"
    }

    private func isAudioFile(_ url: URL) -> Bool {
        let audioExts = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]
        return audioExts.contains(url.pathExtension.lowercased())
    }

    private func ocrFieldLabel(_ key: String) -> String {
        switch key {
        case "bean_name": return "咖啡豆"
        case "bean_weight_g": return "粉重"
        case "grind_setting": return "研磨刻度"
        case "grinder_model": return "磨豆机"
        case "pressure_bar": return "压力"
        case "water_temp_c": return "水温"
        case "yield_g": return "液重"
        case "extraction_time_s": return "时间"
        default: return key
        }
    }
}

import SwiftUI
import AVKit
import PocketCoffeeCore
#if canImport(UIKit)
import UIKit
#endif

struct ReportsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var filter: ReportFilter = .all

    enum ReportFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case brew = "制作报告"
        case equipment = "设备建档"
        var id: String { rawValue }
    }

    private var filteredRecords: [CoffeeRecord] {
        switch filter {
        case .all: return viewModel.records
        case .brew: return viewModel.records.filter { $0.recordType == .brewReport }
        case .equipment: return viewModel.records.filter { $0.recordType == .equipmentProfile }
        }
    }

    var body: some View {
        NavigationStack(path: $viewModel.reportNavigationPath) {
            VStack(spacing: 0) {
                CoffeeTabHeader(
                    title: "咖啡报告",
                    subtitle: "共 \(viewModel.records.count) 条制作与设备记录",
                    subtitleIcon: "cup.and.saucer.fill",
                    subtitleIconColor: CoffeeTheme.cremaAccent
                )

                Picker("记录类型", selection: $filter) {
                    ForEach(ReportFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

                if filteredRecords.isEmpty {
                    ContentUnavailableView(
                        "暂无咖啡记录",
                        systemImage: "cup.and.saucer",
                        description: Text("前往「拍摄/导入」标签页导入视频、录制语音或输入冲煮笔记，即可在端侧生成专属报告。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredRecords) { record in
                            ZStack {
                                NavigationLink(value: record.id) {
                                    EmptyView()
                                }
                                .opacity(0)

                                recordRow(record)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    viewModel.deleteRecord(id: record.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { recordID in
                if let record = viewModel.record(for: recordID) {
                    ReportDetailView(record: record)
                } else {
                    Text("未找到该记录")
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
            }
            .onChange(of: viewModel.selectedRecordID) { _, newID in
                if let newID, viewModel.reportNavigationPath.last != newID {
                    viewModel.reportNavigationPath = [newID]
                }
            }
            .onAppear {
                if let pendingID = viewModel.selectedRecordID, viewModel.reportNavigationPath.last != pendingID {
                    viewModel.reportNavigationPath = [pendingID]
                }
            }
        }
    }

    private func recordRow(_ record: CoffeeRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(recordTitle(record))
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                recordBadge(record)
            }

            if record.recordType == .equipmentProfile {
                Text("共收录 \(record.equipmentItems.count) 件咖啡设备 · \(record.cameraDevice)")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
                    .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    if let dose = record.beanWeightG {
                        metricChip(String(format: "粉 %.1fg", dose))
                    }
                    if let yield = record.yieldG {
                        metricChip(String(format: "液 %.1fg", yield))
                    }
                    if let ratio = record.brewRatio {
                        metricChip(ratio)
                    }
                    if let time = record.extractionTimeS {
                        metricChip(String(format: "%.0fs", time))
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                    Text(Self.formatBrewTimestamp(record.createdAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CoffeeTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: record.mediaKind == .video ? "video.fill" : (record.mediaKind == .audio ? "waveform" : "doc.text"))
                        .font(.system(size: 9))
                        .foregroundStyle(CoffeeTheme.cremaAccent.opacity(0.85))
                    Text(Self.displayCameraDevice(for: record))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(CoffeeTheme.mutedText)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.mutedText.opacity(0.6))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CoffeeTheme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func metricChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(CoffeeTheme.cremaLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CoffeeTheme.cardElevated, in: Capsule())
            .lineLimit(1)
    }

    static func displayCameraDevice(for record: CoffeeRecord) -> String {
        let raw = record.cameraDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return raw
        }
        return record.sourceType.displayName
    }

    private func shortSourceLabel(_ source: SourceType) -> String {
        switch source {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .mac: return "Mac"
        case .djiPocket: return "DJI Pocket"
        case .audioNote: return "语音录制"
        case .manualText: return "手动记录"
        case .webUpload: return "网页导入"
        }
    }

    static func formatBrewTimestamp(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "--" }
        // Trim seconds if standard "yyyy-MM-dd HH:mm:ss" -> "yyyy-MM-dd HH:mm"
        if trimmed.count >= 16 {
            return String(trimmed.prefix(16))
        }
        return trimmed
    }

    private func recordTitle(_ record: CoffeeRecord) -> String {
        if record.recordType == .equipmentProfile {
            return record.equipmentItems.first?.name ?? "咖啡设备建档"
        }
        let bean = record.beanName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = record.brewMethod?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (bean, method) {
        case let (b?, m?) where !b.isEmpty && !m.isEmpty: return "\(b) · \(m)"
        case let (b?, _) where !b.isEmpty: return b
        case let (_, m?) where !m.isEmpty: return m
        default: return "咖啡制作记录"
        }
    }

    @ViewBuilder
    private func recordBadge(_ record: CoffeeRecord) -> some View {
        if record.recordType == .equipmentProfile {
            badgePill("设备建档", color: CoffeeTheme.equipmentBlue)
        } else if record.status == "complete" {
            badgePill("完整报告", color: CoffeeTheme.successGreen)
        } else {
            badgePill("待补全(\(record.missingFields.count))", color: CoffeeTheme.warningAmber)
        }
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Detail View

struct ReportDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let record: CoffeeRecord

    @State private var showSupplementSheet: Bool = false
    @State private var showXiaohongshuStudio: Bool = false
    @State private var player: AVPlayer?

    private var liveRecord: CoffeeRecord {
        viewModel.record(for: record.id) ?? record
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                reportMetaCard

                if let videoURL = resolvedLocalMediaURL(liveRecord.videoPath) {
                    mediaPlayerSection(videoURL)
                }

                if liveRecord.recordType == .equipmentProfile {
                    equipmentItemsSection
                } else {
                    if !liveRecord.missingFields.isEmpty {
                        missingFieldsBanner
                    }
                    flavorRadarSection
                    brewMetricsGrid
                }

                diagnosisSection
                socialCopySection

                if !liveRecord.transcript.isEmpty {
                    transcriptSection
                }
            }
            .padding(16)
        }
        .background(CoffeeTheme.espressoBg.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(liveRecord.recordType == .equipmentProfile ? "设备建档详情" : (liveRecord.beanName ?? "咖啡报告"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if liveRecord.recordType == .brewReport && !liveRecord.missingFields.isEmpty {
                    Button {
                        showSupplementSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                if viewModel.lanSyncEnabled {
                    Button {
                        Task { await viewModel.syncRecordToMacHub(liveRecord) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .sheet(isPresented: $showSupplementSheet) {
            SupplementRecordSheet(record: liveRecord)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showXiaohongshuStudio) {
            XiaohongshuShareStudioView(record: liveRecord)
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var reportMetaCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.cremaAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("制作时间")
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.mutedText)
                Text(ReportsTabView.formatBrewTimestamp(liveRecord.createdAt))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(CoffeeTheme.warmText)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: liveRecord.mediaKind == .video ? "video.fill" : (liveRecord.mediaKind == .audio ? "waveform" : "doc.text"))
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.cremaAccent)
                Text(ReportsTabView.displayCameraDevice(for: liveRecord))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(CoffeeTheme.cardElevated, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(detailCardBackground)
    }

    private func resolvedLocalMediaURL(_ path: String?) -> URL? {
        guard let resolved = SandboxPathResolver.resolveLocalFilePath(path) else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    private func mediaPlayerSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始拍摄回放")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                Label("拍自 \(ReportsTabView.displayCameraDevice(for: liveRecord))", systemImage: "camera.aperture")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(CoffeeTheme.mutedText)
            }

            VideoPlayer(player: player)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear {
                    if player == nil {
                        player = AVPlayer(url: url)
                    }
                }
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private var missingFieldsBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(CoffeeTheme.warningAmber)
                Text("尚有 \(liveRecord.missingFields.count) 项核心参数待补全")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.warmText)
                Spacer()
            }
            Text(liveRecord.missingFields.map(\.label).joined(separator: "、"))
                .font(.caption)
                .foregroundStyle(CoffeeTheme.mutedText)

            Button {
                showSupplementSheet = true
            } label: {
                Label("补全缺失参数并重新分析", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(CoffeeTheme.warningAmber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(CoffeeTheme.espressoBg)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CoffeeTheme.warningAmber.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoffeeTheme.warningAmber.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var flavorRadarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("六维风味雷达图", systemImage: "hexagon.fill")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                if !liveRecord.flavorNotes.isEmpty {
                    Text(liveRecord.flavorNotes.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.cremaAccent)
                        .lineLimit(1)
                }
            }

            FlavorRadarChart(profile: liveRecord.flavorProfile)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private var brewMetricsGrid: some View {
        let metrics: [(String, String, String)] = [
            ("咖啡豆", liveRecord.beanName ?? "待补全", "leaf.fill"),
            ("称重粉量", liveRecord.beanWeightG.map { String(format: "%.1f g", $0) } ?? "待补全", "scalemass.fill"),
            ("研磨刻度", liveRecord.grindSetting ?? "待补全", "dial.medium.fill"),
            ("磨豆机型号", liveRecord.grinderModel ?? liveRecord.grinderType ?? "待补全", "gearshape.fill"),
            ("制作方式", liveRecord.brewMethod ?? "待补全", "cup.and.saucer.fill"),
            ("萃取液重", liveRecord.yieldG.map { String(format: "%.1f g", $0) } ?? "待补全", "drop.fill"),
            ("萃取时间", liveRecord.extractionTimeS.map { String(format: "%.1f s", $0) } ?? "待补全", "timer"),
            ("压力 / 粉液比", formattedPressureRatio, "gauge.with.needle.fill"),
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("8 项核心冲煮参数")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(metrics, id: \.0) { title, value, icon in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: icon)
                                .font(.caption2)
                                .foregroundStyle(CoffeeTheme.cremaAccent)
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(CoffeeTheme.mutedText)
                        }
                        Text(value)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(value == "待补全" ? CoffeeTheme.warningAmber : CoffeeTheme.warmText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private var formattedPressureRatio: String {
        let p = liveRecord.pressureBar.map { String(format: "%.1f bar", $0) }
        let r = liveRecord.brewRatio
        switch (p, r) {
        case let (p?, r?): return "\(p) · \(r)"
        case let (p?, nil): return p
        case let (nil, r?): return r
        case (nil, nil): return "待补全"
        }
    }

    private var equipmentItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("识别到的咖啡设备（\(liveRecord.equipmentItems.count)）", systemImage: "wrench.and.screwdriver.fill")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.equipmentBlue)

            if liveRecord.equipmentItems.isEmpty {
                Text("未识别到具体设备条目，可在「豆库&设备」手动完善永久设备档案。")
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.mutedText)
            } else {
                ForEach(liveRecord.equipmentItems) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.warmText)
                            Spacer()
                            Text(item.category)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CoffeeTheme.equipmentBlue.opacity(0.18), in: Capsule())
                                .foregroundStyle(CoffeeTheme.equipmentBlue)
                        }
                        if !item.spec.isEmpty {
                            Text("规格：\(item.spec)")
                                .font(.caption)
                                .foregroundStyle(CoffeeTheme.cremaLight)
                        }
                        if !item.role.isEmpty {
                            Text(item.role)
                                .font(.caption)
                                .foregroundStyle(CoffeeTheme.mutedText)
                        }
                    }
                    .padding(12)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private var diagnosisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI 咖啡师诊断与建议", systemImage: "brain.head.profile")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            if !liveRecord.extractionDiagnosis.isEmpty {
                Text(liveRecord.extractionDiagnosis)
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !liveRecord.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(liveRecord.suggestions.enumerated()), id: \.offset) { idx, suggestion in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1).")
                                .font(.caption.bold())
                                .foregroundStyle(CoffeeTheme.cremaAccent)
                            Text(suggestion)
                                .font(.subheadline)
                                .foregroundStyle(CoffeeTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private var socialCopySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("一键分享与图文排版", systemImage: "square.and.arrow.up")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            Button {
                showXiaohongshuStudio = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "photo.stack.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("小红书 3:4 图文 / 实况特写一键排版")
                            .font(.subheadline.weight(.bold))
                        Text("自动生成封面海报 + 咖啡机/咖啡豆/萃取特写分镜卡，一键存相册并复制文案")
                            .font(.caption2)
                            .opacity(0.9)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.90, green: 0.24, blue: 0.30), Color(red: 0.76, green: 0.16, blue: 0.24)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if !liveRecord.xiaohongshuCopy.isEmpty {
                copyCard(title: "小红书种草笔记", content: liveRecord.xiaohongshuCopy, badgeColor: .pink)
            }

            if !liveRecord.wechatCopy.isEmpty {
                copyCard(title: "微信朋友圈文案", content: liveRecord.wechatCopy, badgeColor: CoffeeTheme.successGreen)
            }
        }
        .padding(14)
        .background(detailCardBackground)
    }

    private func copyCard(title: String, content: String, badgeColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badgeColor)
                Spacer()
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = content
                    #endif
                    viewModel.showStatus("已复制\(title)")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                ShareLink(item: content) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Text(content)
                .font(.footnote)
                .foregroundStyle(CoffeeTheme.warmText)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别原声 / 笔记文本")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CoffeeTheme.mutedText)
            Text(liveRecord.transcript)
                .font(.footnote)
                .foregroundStyle(CoffeeTheme.warmText.opacity(0.85))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(detailCardBackground)
    }

    private var detailCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }
}

// MARK: - 6-Axis Flavor Radar Chart

struct FlavorRadarChart: View {
    let profile: FlavorProfile

    private var axes: [(label: String, value: Double)] {
        [
            ("酸度", profile.acidity),
            ("甜感", profile.sweetness),
            ("醇厚", profile.body),
            ("香气", profile.aroma),
            ("余韵", profile.aftertaste),
            ("平衡", profile.balance),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size * 0.34

            ZStack {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RadarPolygonShape(values: Array(repeating: level, count: 6))
                        .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2)
                }

                RadarAxesShape(count: 6)
                    .stroke(CoffeeTheme.cardBorder.opacity(0.6), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)

                let normalized = axes.map { min(max($0.value / 10.0, 0.05), 1.0) }
                RadarPolygonShape(values: normalized)
                    .fill(CoffeeTheme.cremaAccent.opacity(0.32))
                    .frame(width: radius * 2, height: radius * 2)

                RadarPolygonShape(values: normalized)
                    .stroke(CoffeeTheme.cremaAccent, lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)

                ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
                    let angle = (Double(index) * (2 * .pi / 6.0)) - (.pi / 2)
                    let labelRadius = radius + 28
                    let x = center.x + CGFloat(cos(angle)) * labelRadius
                    let y = center.y + CGFloat(sin(angle)) * labelRadius

                    VStack(spacing: 1) {
                        Text(axis.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CoffeeTheme.warmText)
                        Text(String(format: "%.1f", axis.value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(CoffeeTheme.cremaAccent)
                    }
                    .position(x: x, y: y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct RadarPolygonShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 3 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        for (index, rawValue) in values.enumerated() {
            let angle = (Double(index) * (2 * .pi / Double(values.count))) - (.pi / 2)
            let r = radius * CGFloat(rawValue)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * r,
                y: center.y + CGFloat(sin(angle)) * r
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

private struct RadarAxesShape: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<count {
            let angle = (Double(index) * (2 * .pi / Double(count))) - (.pi / 2)
            path.move(to: center)
            path.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            ))
        }
        return path
    }
}

// MARK: - Missing-Field Supplement Sheet

struct SupplementRecordSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let record: CoffeeRecord
    @State private var fieldInputs: [String: String] = [:]
    @State private var supplementText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("按缺失字段补充") {
                    ForEach(record.missingFields) { missing in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(missing.label)
                                .font(.caption)
                                .foregroundStyle(CoffeeTheme.mutedText)
                            TextField("输入 \(missing.label)", text: binding(for: missing.field))
                                .textInputAutocapitalization(.never)
                        }
                    }
                }

                Section("或一句话补充说明") {
                    TextEditor(text: $supplementText)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle("补全缺失参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并重算") {
                        let cleaned = fieldInputs.compactMapValues { val -> String? in
                            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        viewModel.supplementRecord(
                            id: record.id,
                            supplementText: supplementText.trimmingCharacters(in: .whitespacesAndNewlines),
                            updates: cleaned
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fieldInputs[key] ?? "" },
            set: { fieldInputs[key] = $0 }
        )
    }
}

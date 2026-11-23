import SwiftUI
import PhotosUI
import PocketCoffeeCore
#if canImport(UIKit)
import UIKit
#endif

struct BeansEquipmentTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    private struct BeanEditorRequest: Identifiable {
        let id = UUID()
        let bean: BeanEntry
        let matchedExistingBean: BeanEntry?
        let isNewScan: Bool
    }

    @State private var section: LibrarySection = .beans
    @State private var beanLabelText: String = ""
    @State private var showBeanImportSheet: Bool = false
    @State private var beanImportSheetHeight: CGFloat = 340
    @State private var beanImportDetent: PresentationDetent = .height(340)
    @State private var editorRequest: BeanEditorRequest?
    @State private var showBeanCameraPicker: Bool = false
    @State private var selectedBeanPhotoItems: [PhotosPickerItem] = []
    #if canImport(UIKit)
    @State private var pendingCapturedBagPhotos: [UIImage] = []
    #endif
    @State private var isScanningBeanPhoto: Bool = false
    @State private var showMachineCameraPicker: Bool = false
    @State private var selectedMachinePhotoItem: PhotosPickerItem?
    @State private var isBatchDeleteMode: Bool = false
    @State private var selectedBeanIDs: Set<String> = []
    @State private var pendingSingleDeleteBean: BeanEntry?
    @State private var showBatchDeleteConfirm: Bool = false

    // Equipment inline editor draft
    @State private var draftEquipment: EquipmentProfile = EquipmentProfile()
    @State private var showAddAccessorySheet: Bool = false

    enum LibrarySection: String, CaseIterable, Identifiable {
        case beans = "咖啡豆库"
        case equipment = "永久设备档案"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CoffeeTabHeader(
                    title: "豆库与设备",
                    subtitle: "在库 \(viewModel.beanLibrary.beans.count) 款咖啡豆 · \(viewModel.beanLibrary.equipment.accessories.count) 件配件",
                    subtitleIcon: "shippingbox.fill",
                    subtitleIconColor: CoffeeTheme.cremaAccent
                )

                Picker("模块", selection: $section) {
                    ForEach(LibrarySection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

                if section == .beans {
                    beansNativeList
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            equipmentProfileSection
                        }
                        .padding(16)
                    }
                }
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                draftEquipment = viewModel.beanLibrary.equipment
            }
            .onChange(of: viewModel.beanLibrary.equipment) { _, updated in
                draftEquipment = updated
            }
            .onChange(of: section) { oldSection, newSection in
                if oldSection == .equipment && draftEquipment != viewModel.beanLibrary.equipment {
                    viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                }
                if newSection != .beans {
                    exitBatchDeleteMode()
                }
            }
            .onDisappear {
                if draftEquipment != viewModel.beanLibrary.equipment {
                    viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                }
            }
            .sheet(item: $editorRequest) { req in
                BeanEditorSheet(
                    bean: req.bean,
                    matchedExistingBean: req.matchedExistingBean,
                    isNewScan: req.isNewScan,
                    onSave: { updated in
                        viewModel.saveBean(updated)
                    },
                    onDelete: { id in
                        viewModel.deleteBean(id: id)
                    }
                )
            }
            .sheet(isPresented: $showBeanImportSheet) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "text.viewfinder")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.cremaAccent)
                                .frame(width: 34, height: 34)
                                .background(CoffeeTheme.espressoBg.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(CoffeeTheme.cremaAccent.opacity(0.35), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("豆袋解析入库")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(CoffeeTheme.warmText)
                                Text("支持拍正反面、相册多选（最多 4 张）或粘贴标签文字")
                                    .font(.caption2)
                                    .foregroundStyle(CoffeeTheme.mutedText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 6)

                            Button {
                                showBeanImportSheet = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(CoffeeTheme.mutedText)
                                    .frame(width: 28, height: 28)
                                    .background(CoffeeTheme.espressoBg.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        beanLabelParserCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    let target = max(290, min(proxy.size.height, 660))
                                    beanImportSheetHeight = target
                                    beanImportDetent = .height(target)
                                }
                                .onChange(of: proxy.size.height) { _, newHeight in
                                    let target = max(290, min(newHeight, 660))
                                    beanImportSheetHeight = target
                                    if beanImportDetent != .large {
                                        beanImportDetent = .height(target)
                                    }
                                }
                        }
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(CoffeeTheme.cardElevated.ignoresSafeArea())
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(CoffeeTheme.cremaAccent.opacity(0.28), lineWidth: 1)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
                #if canImport(UIKit)
                .fullScreenCover(isPresented: $showBeanCameraPicker) {
                    BeanBagCameraPicker { capturedImage in
                        if pendingCapturedBagPhotos.count < 4 {
                            pendingCapturedBagPhotos.append(capturedImage)
                        }
                    }
                    .ignoresSafeArea()
                }
                #endif
                .presentationDetents([.height(beanImportSheetHeight), .large], selection: $beanImportDetent)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .presentationBackground(CoffeeTheme.cardElevated)
            }
            .sheet(isPresented: $showAddAccessorySheet) {
                AddAccessorySheet { item in
                    draftEquipment.accessories.append(item)
                    viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                }
            }
            #if canImport(UIKit)
            .fullScreenCover(isPresented: $showMachineCameraPicker) {
                BeanBagCameraPicker { capturedImage in
                    if let path = viewModel.saveMachinePhoto(capturedImage) {
                        draftEquipment.machinePhotoPath = path
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedBeanPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    isScanningBeanPhoto = true
                    defer {
                        isScanningBeanPhoto = false
                        selectedBeanPhotoItems = []
                    }
                    let maxPhotoBytes = 30 * 1024 * 1024
                    var loadedImages: [UIImage] = []
                    for item in newItems.prefix(4) {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           !data.isEmpty,
                           data.count <= maxPhotoBytes,
                           let image = UIImage(data: data) {
                            loadedImages.append(image)
                        }
                    }
                    if !loadedImages.isEmpty {
                        await processBeanBagImages(loadedImages)
                    } else {
                        viewModel.showError("未能读取所选豆袋照片（单张需小于 30MB），请重试")
                    }
                }
            }
            .onChange(of: selectedMachinePhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    defer { selectedMachinePhotoItem = nil }
                    let maxPhotoBytes = 30 * 1024 * 1024
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       !data.isEmpty,
                       data.count <= maxPhotoBytes,
                       let image = UIImage(data: data),
                       let path = viewModel.saveMachinePhoto(image) {
                        draftEquipment.machinePhotoPath = path
                    } else {
                        viewModel.showError("未能读取所选咖啡机照片（单张需小于 30MB），请重试")
                    }
                }
            }
            #endif
            .alert(
                "确认删除这款咖啡豆？",
                isPresented: Binding(
                    get: { pendingSingleDeleteBean != nil },
                    set: { if !$0 { pendingSingleDeleteBean = nil } }
                )
            ) {
                Button("取消", role: .cancel) { pendingSingleDeleteBean = nil }
                Button("确认删除", role: .destructive) {
                    if let target = pendingSingleDeleteBean {
                        viewModel.deleteBean(id: target.id)
                    }
                    pendingSingleDeleteBean = nil
                }
            } message: {
                Text("将从豆库移除「\(pendingSingleDeleteBean?.fullName ?? "")」，不会影响历史制作报告。")
            }
            .alert("确认批量删除 \(selectedBeanIDs.count) 款咖啡豆？", isPresented: $showBatchDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除所选 (\(selectedBeanIDs.count))", role: .destructive) {
                    viewModel.deleteBeans(ids: selectedBeanIDs)
                    exitBatchDeleteMode()
                }
            } message: {
                Text("删除后将从咖啡豆库移除所选条目，不会影响已生成的历史制作报告。")
            }
            .safeAreaInset(edge: .bottom) {
                if section == .beans && isBatchDeleteMode {
                    batchDeleteBottomBar
                }
            }
        }
    }

    // MARK: - Bean Label Parser & Inventory

    private var beanLabelParserCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if canImport(UIKit)
            HStack(spacing: 10) {
                Button {
                    if pendingCapturedBagPhotos.count >= 4 {
                        viewModel.showError("单次最多拍摄 4 张豆袋照片，请先点击下方合并识别")
                    } else if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showBeanCameraPicker = true
                    } else {
                        viewModel.showError("当前设备不支持相机，请使用右侧「相册多选」")
                    }
                } label: {
                    Label(pendingCapturedBagPhotos.isEmpty ? "拍照扫豆袋" : "继续拍背面", systemImage: "camera.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(CoffeeTheme.espressoBg)
                }
                .buttonStyle(.borderless)
                .disabled(isScanningBeanPhoto)

                PhotosPicker(
                    selection: $selectedBeanPhotoItems,
                    maxSelectionCount: 4,
                    matching: .images,
                    preferredItemEncoding: .compatible
                ) {
                    Label("相册多选", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(CoffeeTheme.espressoBg.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(CoffeeTheme.cremaAccent.opacity(0.55), lineWidth: 1)
                        )
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .buttonStyle(.borderless)
                .disabled(isScanningBeanPhoto)
            }

            if !pendingCapturedBagPhotos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已拍 \(pendingCapturedBagPhotos.count) 张豆袋图（可点上方「继续拍背面」）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CoffeeTheme.cremaLight)
                        Spacer()
                        Button("清空") {
                            pendingCapturedBagPhotos.removeAll()
                        }
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.mutedText)
                        .buttonStyle(.borderless)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pendingCapturedBagPhotos.enumerated()), id: \.offset) { idx, img in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 66, height: 66)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    Button {
                                        pendingCapturedBagPhotos.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.white, CoffeeTheme.dangerRed)
                                            .padding(2)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    Button {
                        let batch = pendingCapturedBagPhotos
                        pendingCapturedBagPhotos.removeAll()
                        Task { await processBeanBagImages(batch) }
                    } label: {
                        Label("合并识别这 \(pendingCapturedBagPhotos.count) 张图并直接入库", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(CoffeeTheme.successGreen, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(CoffeeTheme.espressoBg)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isScanningBeanPhoto)
                }
                .padding(10)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if isScanningBeanPhoto {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(CoffeeTheme.cremaAccent)
                    Text("正在合并识别豆袋正反面文字与日期...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    Spacer()
                }
                .padding(10)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            #endif

            ZStack(alignment: .topLeading) {
                if beanLabelText.isEmpty {
                    Text("例如：埃塞俄比亚 耶加雪菲 花魁 水洗 浅烘 250g 柑橘 茉莉花 蜂蜜 推荐刻度15")
                        .font(.subheadline)
                        .foregroundStyle(CoffeeTheme.mutedText.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $beanLabelText)
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.warmText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 74)
                    .padding(4)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CoffeeTheme.espressoBg.opacity(0.68))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                    )
            )

            Button {
                if viewModel.parseAndAddBean(labelText: beanLabelText) != nil {
                    beanLabelText = ""
                    showBeanImportSheet = false
                }
            } label: {
                Label("端侧解析并加入豆库", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(CoffeeTheme.espressoBg)
            }
        }
    }

    private var hasSeededSampleBeans: Bool {
        viewModel.beanLibrary.beans.contains { BeanEquipmentStore.seededSampleBeanIDs.contains($0.id) }
    }

    private var beansNativeList: some View {
        List {
            HStack(spacing: 8) {
                Text(
                    isBatchDeleteMode
                        ? "批量删除（已选 \(selectedBeanIDs.count)/\(viewModel.beanLibrary.beans.count)）"
                        : "在库咖啡豆（\(viewModel.beanLibrary.beans.count)）"
                )
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

                Spacer()

                if isBatchDeleteMode {
                    Button("完成") {
                        exitBatchDeleteMode()
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CoffeeTheme.cardElevated, in: Capsule())
                    .foregroundStyle(CoffeeTheme.cremaLight)
                    .buttonStyle(.borderless)
                } else {
                    if !viewModel.beanLibrary.beans.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isBatchDeleteMode = true
                                selectedBeanIDs.removeAll()
                            }
                        } label: {
                            Label("多选", systemImage: "checklist")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(CoffeeTheme.cardElevated, in: Capsule())
                                .foregroundStyle(CoffeeTheme.cremaLight)
                        }
                        .buttonStyle(.borderless)
                    }

                    Button {
                        showBeanImportSheet = true
                    } label: {
                        Label("扫豆袋入库", systemImage: "plus")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(CoffeeTheme.cremaAccent, in: Capsule())
                            .foregroundStyle(CoffeeTheme.espressoBg)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !viewModel.beanLibrary.beans.isEmpty && !isBatchDeleteMode {
                Text("💡 点击卡片编辑余量与日期 · 左滑删除 · 右上角可拍照/多图扫豆袋入库")
                    .font(.caption2)
                    .foregroundStyle(CoffeeTheme.mutedText)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if viewModel.beanLibrary.beans.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("豆库暂无咖啡豆")
                        .font(.headline)
                        .foregroundStyle(CoffeeTheme.warmText)
                    Text("导入咖啡制作视频生成报告时会自动提取咖啡豆与特写图入库，也可拍照或粘贴豆袋标签一键入库。")
                        .font(.subheadline)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    Button {
                        showBeanImportSheet = true
                    } label: {
                        Label("拍照 / 粘贴标签解析入库", systemImage: "text.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(CoffeeTheme.espressoBg)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.beanLibrary.beans) { bean in
                    beanCard(bean)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isBatchDeleteMode {
                                toggleBeanSelection(bean.id)
                            } else {
                                editorRequest = BeanEditorRequest(bean: bean, matchedExistingBean: nil, isNewScan: false)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isBatchDeleteMode {
                                Button(role: .destructive) {
                                    pendingSingleDeleteBean = bean
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var batchDeleteBottomBar: some View {
        let allIDs = Set(viewModel.beanLibrary.beans.map(\.id))
        let allSelected = !allIDs.isEmpty && selectedBeanIDs.count == allIDs.count

        return HStack(spacing: 12) {
            Button {
                if allSelected {
                    selectedBeanIDs.removeAll()
                } else {
                    selectedBeanIDs = allIDs
                }
            } label: {
                Label(allSelected ? "取消全选" : "全选", systemImage: allSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
            }

            Spacer()

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除所选 (\(selectedBeanIDs.count))", systemImage: "trash.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        selectedBeanIDs.isEmpty ? CoffeeTheme.cardElevated : CoffeeTheme.dangerRed,
                        in: Capsule()
                    )
                    .foregroundStyle(selectedBeanIDs.isEmpty ? CoffeeTheme.mutedText : .white)
            }
            .disabled(selectedBeanIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            CoffeeTheme.cardSurface
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(CoffeeTheme.cardBorder),
                    alignment: .top
                )
        )
    }

    private func toggleBeanSelection(_ id: String) {
        if selectedBeanIDs.contains(id) {
            selectedBeanIDs.remove(id)
        } else {
            selectedBeanIDs.insert(id)
        }
    }

    private func exitBatchDeleteMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isBatchDeleteMode = false
            selectedBeanIDs.removeAll()
        }
    }

    #if canImport(UIKit)
    @MainActor
    private func processBeanBagImages(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        isScanningBeanPhoto = true
        defer { isScanningBeanPhoto = false }
        if let result = await viewModel.scanBeanBagPhotos(images) {
            if let matched = result.matchedExistingBean {
                if !result.ocrText.isEmpty {
                    beanLabelText = result.ocrText
                }
                showBeanImportSheet = false
                try? await Task.sleep(nanoseconds: 280_000_000)
                editorRequest = BeanEditorRequest(
                    bean: result.scannedBean,
                    matchedExistingBean: matched,
                    isNewScan: true
                )
            } else {
                viewModel.saveBean(result.scannedBean)
                beanLabelText = ""
                showBeanImportSheet = false
                let countNote = images.count > 1 ? "（合并 \(images.count) 张正反面）" : ""
                viewModel.showStatus("已识别并直接入库：\(result.scannedBean.fullName)\(countNote)")
            }
        }
    }
    #endif

    private func beanCard(_ bean: BeanEntry) -> some View {
        let ratio = bean.initialWeightG > 0 ? min(max(bean.remainingWeightG / bean.initialWeightG, 0), 1) : 0
        let isSample = BeanEquipmentStore.seededSampleBeanIDs.contains(bean.id)
        let isSelected = selectedBeanIDs.contains(bean.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if isBatchDeleteMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? CoffeeTheme.dangerRed : CoffeeTheme.mutedText)
                        .padding(.top, 2)
                }

                #if canImport(UIKit)
                let resolvedPhotos = bean.allPhotoPaths.compactMap { SandboxPathResolver.resolveLocalFilePath($0) }
                if let firstPath = resolvedPhotos.first,
                   let uiImage = UIImage(contentsOfFile: firstPath) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(CoffeeTheme.cremaAccent.opacity(0.45), lineWidth: 1)
                            )

                        if resolvedPhotos.count > 1 {
                            Text("\(resolvedPhotos.count)张")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.7), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                    }
                }
                #endif

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bean.fullName)
                            .font(.headline)
                            .foregroundStyle(CoffeeTheme.warmText)
                        if isSample {
                            Text("示例")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(CoffeeTheme.warningAmber.opacity(0.2), in: Capsule())
                                .foregroundStyle(CoffeeTheme.warningAmber)
                        }
                    }
                    if !bean.roastDate.isEmpty {
                        Text("生产/烘焙：\(bean.roastDate)")
                            .font(.caption2)
                            .foregroundStyle(CoffeeTheme.mutedText)
                    }
                    if !bean.expiryDate.isEmpty {
                        Text("赏味/到期：\(bean.expiryDate)")
                            .font(.caption2)
                            .foregroundStyle(CoffeeTheme.mutedText)
                    }
                }
                Spacer(minLength: 4)
                Text(bean.roastLevel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CoffeeTheme.cremaAccent.opacity(0.2), in: Capsule())
                    .foregroundStyle(CoffeeTheme.cremaLight)
            }

            if let freshness = bean.freshnessInfo() {
                HStack(alignment: .center, spacing: 8) {
                    Text(freshness.badgeText)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(freshnessColor(freshness.level).opacity(0.2), in: Capsule())
                        .foregroundStyle(freshnessColor(freshness.level))

                    Text(freshness.detailText)
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.mutedText)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(format: "剩余 %.1fg / %.0fg", bean.remainingWeightG, bean.initialWeightG))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(CoffeeTheme.warmText)
                    Spacer()
                    Text("已制作 \(bean.shotsCount) 杯")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
                ProgressView(value: ratio)
                    .tint(ratio < 0.2 ? CoffeeTheme.warningAmber : CoffeeTheme.cremaAccent)
            }

            if !isBatchDeleteMode {
                HStack(spacing: 8) {
                    Button {
                        var updated = bean
                        updated.remainingWeightG = max(0, (updated.remainingWeightG - 18.0) * 10).rounded() / 10
                        updated.shotsCount += 1
                        viewModel.saveBean(updated)
                    } label: {
                        Label("-18g 记一杯", systemImage: "minus.circle")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(CoffeeTheme.cardElevated, in: Capsule())
                            .foregroundStyle(CoffeeTheme.cremaLight)
                    }
                    .buttonStyle(.borderless)

                    Button {
                        editorRequest = BeanEditorRequest(bean: bean, matchedExistingBean: nil, isNewScan: false)
                    } label: {
                        Label("编辑余量与日期", systemImage: "slider.horizontal.3")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(CoffeeTheme.cremaAccent.opacity(0.18), in: Capsule())
                            .foregroundStyle(CoffeeTheme.cremaAccent)
                    }
                    .buttonStyle(.borderless)

                    Spacer()
                }
            }

            if !bean.recommendedGrind.isEmpty {
                Text("推荐研磨度：\(bean.recommendedGrind)")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.cremaLight)
            }

            if !bean.flavorTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bean.flavorTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(CoffeeTheme.cardElevated, in: Capsule())
                                .foregroundStyle(CoffeeTheme.warmText)
                        }
                    }
                }
            }

            if !bean.goldenRecipeNote.isEmpty {
                Text("黄金配方：\(bean.goldenRecipeNote)")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Permanent Equipment Profile

    private var equipmentProfileSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title3)
                    .foregroundStyle(CoffeeTheme.equipmentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("永久设备档案")
                        .font(.headline)
                        .foregroundStyle(CoffeeTheme.warmText)
                    Text("拍摄或口述设备介绍视频/语音时会自动同步更新此档案，也可在此手动编辑。")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("我的咖啡机定妆照", systemImage: "camera.macro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    Spacer()
                    #if canImport(UIKit)
                    Button {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showMachineCameraPicker = true
                        } else {
                            viewModel.showError("当前设备不支持相机，请使用右侧相册选图")
                        }
                    } label: {
                        Label("拍照", systemImage: "camera.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(CoffeeTheme.cardElevated, in: Capsule())
                            .foregroundStyle(CoffeeTheme.cremaAccent)
                    }

                    PhotosPicker(
                        selection: $selectedMachinePhotoItem,
                        matching: .images,
                        preferredItemEncoding: .compatible
                    ) {
                        Label("相册", systemImage: "photo.on.rectangle")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(CoffeeTheme.cardElevated, in: Capsule())
                            .foregroundStyle(CoffeeTheme.cremaLight)
                    }
                    #endif
                }

                #if canImport(UIKit)
                if let resolved = SandboxPathResolver.resolveLocalFilePath(draftEquipment.machinePhotoPath),
                   let uiImage = UIImage(contentsOfFile: resolved) {
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.65)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text(draftEquipment.espressoMachine)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.title2)
                            .foregroundStyle(CoffeeTheme.cremaAccent.opacity(0.8))
                            .frame(width: 48, height: 48)
                            .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(draftEquipment.espressoMachine)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.warmText)
                            Text("点右上角「拍照」或「相册」为你的咖啡机添加实拍照片")
                                .font(.caption2)
                                .foregroundStyle(CoffeeTheme.mutedText)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(CoffeeTheme.cardElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                #endif
            }
            .padding(14)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 12) {
                Text("核心设备配置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.cremaLight)

                labeledTextField("意式咖啡机 / 主设备", text: $draftEquipment.espressoMachine)
                labeledTextField("默认磨豆机类型", text: $draftEquipment.defaultGrinderType)
                labeledTextField("主力磨豆机型号", text: $draftEquipment.defaultGrinderModel)
                labeledTextField("备用磨豆机型号", text: $draftEquipment.secondaryGrinderModel)

                HStack {
                    Text("默认冲煮水温 (°C)")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    Spacer()
                    Stepper(
                        String(format: "%.1f°C", draftEquipment.defaultWaterTempC),
                        value: $draftEquipment.defaultWaterTempC,
                        in: 80...100,
                        step: 0.5
                    )
                    .labelsHidden()
                    .onChange(of: draftEquipment.defaultWaterTempC) { _, _ in
                        viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                    }
                    Text(String(format: "%.1f°C", draftEquipment.defaultWaterTempC))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(CoffeeTheme.warmText)
                        .frame(width: 58, alignment: .trailing)
                }

                Toggle(isOn: $draftEquipment.autoFillDefaultGrinder) {
                    Text("未提及磨豆机时自动填充默认设备")
                        .font(.subheadline)
                        .foregroundStyle(CoffeeTheme.warmText)
                }
                .tint(CoffeeTheme.cremaAccent)
                .onChange(of: draftEquipment.autoFillDefaultGrinder) { _, _ in
                    viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                }
            }
            .padding(14)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("咖啡配件清单（\(draftEquipment.accessories.count)）", systemImage: "wrench.and.screwdriver.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    Spacer()
                    Button {
                        showAddAccessorySheet = true
                    } label: {
                        Label("添加配件", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(CoffeeTheme.cremaAccent, in: Capsule())
                            .foregroundStyle(CoffeeTheme.espressoBg)
                    }
                }

                if draftEquipment.accessories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title3)
                            .foregroundStyle(CoffeeTheme.mutedText.opacity(0.7))
                        Text("暂无配件记录")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CoffeeTheme.warmText)
                        Text("制作报告中提到器具时会自动导入，也可点右上角「+ 添加配件」手动添加。")
                            .font(.caption)
                            .foregroundStyle(CoffeeTheme.mutedText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                    .background(CoffeeTheme.cardElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        ForEach(draftEquipment.accessories) { item in
                            HStack(spacing: 10) {
                                Image(systemName: accessoryIcon(for: item.category))
                                    .font(.subheadline)
                                    .foregroundStyle(CoffeeTheme.cremaAccent)
                                    .frame(width: 34, height: 34)
                                    .background(CoffeeTheme.cardSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(CoffeeTheme.warmText)
                                            .lineLimit(1)
                                        if !item.category.isEmpty {
                                            Text(item.category)
                                                .font(.caption2.weight(.medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(CoffeeTheme.cremaAccent.opacity(0.16), in: Capsule())
                                                .foregroundStyle(CoffeeTheme.cremaLight)
                                        }
                                    }
                                    let detail = [item.spec, item.role].filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(CoffeeTheme.mutedText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button(role: .destructive) {
                                    draftEquipment.accessories.removeAll { $0.id == item.id }
                                    viewModel.saveEquipmentProfile(draftEquipment, silent: true)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.body)
                                        .foregroundStyle(CoffeeTheme.mutedText.opacity(0.8))
                                }
                                .accessibilityLabel("移除配件 \(item.name)")
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(CoffeeTheme.cardElevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }
            .padding(14)
            .background(cardBackground)

            Button {
                viewModel.saveEquipmentProfile(draftEquipment)
            } label: {
                Label("保存永久设备档案", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(CoffeeTheme.espressoBg)
            }
        }
    }

    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(CoffeeTheme.mutedText)
            TextField(label, text: text)
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.warmText)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
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

    private func accessoryIcon(for category: String) -> String {
        if category.contains("秤") || category.contains("称重") { return "scalemass.fill" }
        if category.contains("压粉") || category.contains("布粉") { return "hammer.fill" }
        if category.contains("手柄") || category.contains("萃取") || category.contains("滤") { return "cup.and.saucer.fill" }
        if category.contains("奶") || category.contains("拉花") { return "drop.fill" }
        if category.contains("清洁") { return "sparkles" }
        return "wrench.and.screwdriver.fill"
    }

    private func freshnessColor(_ level: BeanFreshnessInfo.Level) -> Color {
        switch level {
        case .resting: return CoffeeTheme.equipmentBlue
        case .peak: return CoffeeTheme.successGreen
        case .steady: return CoffeeTheme.cremaAccent
        case .fading: return CoffeeTheme.warningAmber
        case .expired: return CoffeeTheme.dangerRed
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }
}

// MARK: - Bean Editor Sheet (Remaining Weight, Roast/Expiry Dates & Flavor Profile)

private struct BeanEditorSheet: View {
    let scannedBean: BeanEntry
    let matchedExistingBean: BeanEntry?
    let isNewScan: Bool
    let onSave: (BeanEntry) -> Void
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var activeBaseBean: BeanEntry
    @State private var mergeMode: BeanScanMergeMode = .supplementCurrent
    @State private var fullName: String
    @State private var roastLevel: String
    @State private var initialWeightG: Double
    @State private var remainingWeightG: Double
    @State private var remainingText: String
    @State private var initialText: String
    @State private var roastDate: Date
    @State private var hasExpiryDate: Bool
    @State private var expiryDate: Date
    @State private var recommendedGrind: String
    @State private var flavorTagsText: String
    @State private var goldenRecipeNote: String
    @State private var shotsCount: Int
    @State private var showDeleteConfirm: Bool = false

    private static let roastPresets = ["浅度烘焙", "中浅烘焙", "中度烘焙", "中深烘焙", "深度烘焙"]
    private static let bagWeightPresets: [Double] = [100, 200, 227, 250, 500, 1000]

    init(
        bean: BeanEntry,
        matchedExistingBean: BeanEntry? = nil,
        isNewScan: Bool = false,
        onSave: @escaping (BeanEntry) -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self.scannedBean = bean
        self.matchedExistingBean = matchedExistingBean
        self.isNewScan = isNewScan
        self.onSave = onSave
        self.onDelete = onDelete

        let initialBean: BeanEntry
        if let existing = matchedExistingBean {
            initialBean = BeanEquipmentStore.mergeScannedBean(bean, with: existing, mode: .supplementCurrent)
        } else {
            initialBean = bean
        }

        _activeBaseBean = State(initialValue: initialBean)
        _fullName = State(initialValue: initialBean.fullName)
        _roastLevel = State(initialValue: initialBean.roastLevel)
        let initW = max(1, initialBean.initialWeightG)
        let remW = min(max(0, initialBean.remainingWeightG), max(initW, initialBean.remainingWeightG))
        _initialWeightG = State(initialValue: initW)
        _remainingWeightG = State(initialValue: remW)
        _initialText = State(initialValue: Self.fmtWeight(initW))
        _remainingText = State(initialValue: Self.fmtWeight(remW))

        let parsedRoast = BeanEntry.parseISODate(initialBean.roastDate) ?? Date()
        _roastDate = State(initialValue: parsedRoast)

        if let parsedExpiry = BeanEntry.parseISODate(initialBean.expiryDate) {
            _hasExpiryDate = State(initialValue: true)
            _expiryDate = State(initialValue: parsedExpiry)
        } else {
            _hasExpiryDate = State(initialValue: false)
            _expiryDate = State(
                initialValue: Calendar.current.date(byAdding: .day, value: 90, to: parsedRoast) ?? Date()
            )
        }

        _recommendedGrind = State(initialValue: initialBean.recommendedGrind)
        _flavorTagsText = State(initialValue: initialBean.flavorTags.joined(separator: "、"))
        _goldenRecipeNote = State(initialValue: initialBean.goldenRecipeNote)
        _shotsCount = State(initialValue: initialBean.shotsCount)
    }

    private var previewBean: BeanEntry {
        var copy = activeBaseBean
        copy.fullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.roastLevel = roastLevel
        copy.initialWeightG = max(0, initialWeightG)
        copy.remainingWeightG = max(0, remainingWeightG)
        copy.roastDate = Self.isoString(from: roastDate)
        copy.expiryDate = hasExpiryDate ? Self.isoString(from: expiryDate) : ""
        copy.recommendedGrind = recommendedGrind.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.flavorTags = flavorTagsText
            .components(separatedBy: CharacterSet(charactersIn: "、,，/ "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.goldenRecipeNote = goldenRecipeNote.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.shotsCount = max(0, shotsCount)
        return copy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let existing = matchedExistingBean {
                        duplicateMatchBannerCard(existing: existing)
                    }
                    beanPhotosGalleryCard
                    remainingWeightCard
                    datesAndFreshnessCard
                    detailsCard
                    if !isNewScan {
                        deleteZoneCard
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .navigationTitle(isNewScan ? "核对并入库咖啡豆" : "编辑咖啡豆")
            .navigationBarTitleDisplayMode(.inline)
            .alert("确认删除这款咖啡豆？", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认删除", role: .destructive) {
                    onDelete(activeBaseBean.id)
                    dismiss()
                }
            } message: {
                Text("将从咖啡豆库中移除「\(activeBaseBean.fullName)」，不会影响已生成的历史制作报告。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(previewBean)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(CoffeeTheme.cremaAccent)
                }
            }
        }
    }

    // MARK: - 0. Duplicate Match Banner (Smart Merge Mode Picker)

    private func duplicateMatchBannerCard(existing: BeanEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .foregroundStyle(CoffeeTheme.warningAmber)
                Text("检测到豆库已有「\(existing.fullName)」")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CoffeeTheme.warmText)
            }

            Text(
                String(
                    format: "当前库存剩余 %.1fg / %.0fg · 已制作 %d 杯。请选择本次拍照的合并方式：",
                    existing.remainingWeightG,
                    existing.initialWeightG,
                    existing.shotsCount
                )
            )
            .font(.caption)
            .foregroundStyle(CoffeeTheme.mutedText)

            Picker("合并方式", selection: $mergeMode) {
                ForEach(BeanScanMergeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mergeMode) { _, newMode in
                applyMergeMode(newMode, existing: existing)
            }

            Text(mergeModeExplanation(mergeMode, existing: existing))
                .font(.caption2)
                .foregroundStyle(CoffeeTheme.cremaLight)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CoffeeTheme.warningAmber.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoffeeTheme.warningAmber.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func mergeModeExplanation(_ mode: BeanScanMergeMode, existing: BeanEntry) -> String {
        switch mode {
        case .supplementCurrent:
            return "保留原有剩余克重（\(Self.fmtWeight(existing.remainingWeightG))g）与制作杯数，仅更新照片、生产/到期日期与风味。"
        case .restockNewBag:
            return "保留制作杯数，将新袋净重（+\(Self.fmtWeight(scannedBean.initialWeightG))g）累加到当前余量，并更新最新日期与照片。"
        case .createSeparate:
            return "不修改原有豆子，单独创建一条全新的咖啡豆档案。"
        }
    }

    private func applyMergeMode(_ mode: BeanScanMergeMode, existing: BeanEntry) {
        let merged = BeanEquipmentStore.mergeScannedBean(scannedBean, with: existing, mode: mode)
        activeBaseBean = merged
        fullName = merged.fullName
        roastLevel = merged.roastLevel
        initialWeightG = max(1, merged.initialWeightG)
        remainingWeightG = max(0, merged.remainingWeightG)
        initialText = Self.fmtWeight(initialWeightG)
        remainingText = Self.fmtWeight(remainingWeightG)
        if let parsedRoast = BeanEntry.parseISODate(merged.roastDate) {
            roastDate = parsedRoast
        }
        if let parsedExpiry = BeanEntry.parseISODate(merged.expiryDate) {
            hasExpiryDate = true
            expiryDate = parsedExpiry
        } else {
            hasExpiryDate = false
        }
        recommendedGrind = merged.recommendedGrind
        flavorTagsText = merged.flavorTags.joined(separator: "、")
        goldenRecipeNote = merged.goldenRecipeNote
        shotsCount = merged.shotsCount
    }

    // MARK: - Bean Photos Gallery (Front & Back)

    @ViewBuilder
    private var beanPhotosGalleryCard: some View {
        #if canImport(UIKit)
        let resolvedPaths = activeBaseBean.allPhotoPaths.compactMap { SandboxPathResolver.resolveLocalFilePath($0) }
        if !resolvedPaths.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("豆袋实拍照片（\(resolvedPaths.count) 张）", systemImage: "photo.stack.fill")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.cremaLight)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(resolvedPaths.enumerated()), id: \.offset) { idx, path in
                            if let uiImage = UIImage(contentsOfFile: path) {
                                ZStack(alignment: .bottomLeading) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 140, height: 186)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(CoffeeTheme.cremaAccent.opacity(0.45), lineWidth: 1)
                                        )

                                    Text(idx == 0 ? "正面 / 封面" : "图 \(idx + 1)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.68), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(6)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(sheetCardBackground)
        }
        #endif
    }

    // MARK: - 1. Remaining Weight Calibration

    private var remainingWeightCard: some View {
        let sliderMax = max(initialWeightG, max(remainingWeightG, 50))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实际剩余克重校准", systemImage: "scalemass.fill")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                Text(String(format: "%.1fg / %.0fg", remainingWeightG, initialWeightG))
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(CoffeeTheme.cremaAccent)
            }

            Text("平时未录制视频冲煮导致余量有偏差时，可直接拖动滑块或输入实际称重克数。")
                .font(.caption)
                .foregroundStyle(CoffeeTheme.mutedText)

            Slider(
                value: Binding(
                    get: { min(remainingWeightG, sliderMax) },
                    set: { newVal in
                        let rounded = (newVal * 2).rounded() / 2 // 0.5g steps
                        remainingWeightG = rounded
                        remainingText = Self.fmtWeight(rounded)
                    }
                ),
                in: 0...sliderMax
            )
            .tint(CoffeeTheme.cremaAccent)

            HStack(spacing: 8) {
                quickWeightButton("-18g") { adjustRemaining(by: -18) }
                quickWeightButton("-15g") { adjustRemaining(by: -15) }
                quickWeightButton("+18g") { adjustRemaining(by: 18) }
                quickWeightButton("清零") { setRemaining(0) }
                quickWeightButton("满袋") { setRemaining(initialWeightG) }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实际剩余 (g)")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    TextField("例如 165", text: $remainingText)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(CoffeeTheme.warmText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: remainingText) { _, val in
                            if let num = Double(val.trimmingCharacters(in: .whitespacesAndNewlines)), num >= 0 {
                                remainingWeightG = num
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("整袋净重 (g)")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    TextField("例如 250", text: $initialText)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(CoffeeTheme.warmText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: initialText) { _, val in
                            if let num = Double(val.trimmingCharacters(in: .whitespacesAndNewlines)), num > 0 {
                                initialWeightG = num
                            }
                        }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("常用规格:")
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    ForEach(Self.bagWeightPresets, id: \.self) { w in
                        Button("\(Int(w))g") {
                            initialWeightG = w
                            initialText = Self.fmtWeight(w)
                            if remainingWeightG > w {
                                setRemaining(w)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            abs(initialWeightG - w) < 0.5 ? CoffeeTheme.cremaAccent.opacity(0.25) : CoffeeTheme.cardElevated,
                            in: Capsule()
                        )
                        .foregroundStyle(abs(initialWeightG - w) < 0.5 ? CoffeeTheme.cremaAccent : CoffeeTheme.warmText)
                    }
                }
            }
        }
        .padding(14)
        .background(sheetCardBackground)
    }

    // MARK: - 2. Production / Roast Date & Expiry Date

    private var datesAndFreshnessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("生产/烘焙日期 与 赏味/到期日期", systemImage: "calendar.badge.clock")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            DatePicker(
                "生产 / 烘焙日期",
                selection: $roastDate,
                displayedComponents: .date
            )
            .font(.subheadline)
            .foregroundStyle(CoffeeTheme.warmText)
            .tint(CoffeeTheme.cremaAccent)

            Toggle(isOn: $hasExpiryDate) {
                Text("记录赏味期 / 到期日期")
                    .font(.subheadline)
                    .foregroundStyle(CoffeeTheme.warmText)
            }
            .tint(CoffeeTheme.cremaAccent)

            if hasExpiryDate {
                DatePicker(
                    "赏味 / 到期日期",
                    selection: $expiryDate,
                    displayedComponents: .date
                )
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.warmText)
                .tint(CoffeeTheme.cremaAccent)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("按生产日期推算:")
                            .font(.caption2)
                            .foregroundStyle(CoffeeTheme.mutedText)
                        expiryPresetChip("+60天", days: 60)
                        expiryPresetChip("+90天", days: 90)
                        expiryPresetChip("+180天", days: 180)
                        expiryPresetChip("+1年", days: 365)
                    }
                }
            }

            if let info = previewBean.freshnessInfo() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("风味状态预览：\(info.badgeText)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    Text(info.detailText)
                        .font(.caption2)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(sheetCardBackground)
    }

    // MARK: - 3. Bean Metadata & Golden Recipe

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("基础信息与风味档案", systemImage: "cup.and.saucer.fill")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            editorField("咖啡豆名称", text: $fullName)

            VStack(alignment: .leading, spacing: 6) {
                Text("烘焙度")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.roastPresets, id: \.self) { level in
                            Button(level) {
                                roastLevel = level
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                roastLevel == level ? CoffeeTheme.cremaAccent : CoffeeTheme.cardElevated,
                                in: Capsule()
                            )
                            .foregroundStyle(roastLevel == level ? CoffeeTheme.espressoBg : CoffeeTheme.warmText)
                        }
                    }
                }
            }

            editorField("推荐研磨度", text: $recommendedGrind)
            editorField("风味标签（顿号或空格分隔）", text: $flavorTagsText)
            editorField("黄金配方备注", text: $goldenRecipeNote)

            Stepper("已制作杯数：\(shotsCount) 杯", value: $shotsCount, in: 0...999)
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.warmText)
        }
        .padding(14)
        .background(sheetCardBackground)
    }

    private var deleteZoneCard: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("从豆库删除这款咖啡豆", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CoffeeTheme.dangerRed.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(CoffeeTheme.dangerRed.opacity(0.35), lineWidth: 1)
                        )
                )
                .foregroundStyle(CoffeeTheme.dangerRed)
        }
        .padding(.top, 8)
    }

    private func quickWeightButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(CoffeeTheme.cremaLight)
    }

    private func expiryPresetChip(_ title: String, days: Int) -> some View {
        Button(title) {
            if let d = Calendar.current.date(byAdding: .day, value: days, to: roastDate) {
                expiryDate = d
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(CoffeeTheme.cardElevated, in: Capsule())
        .foregroundStyle(CoffeeTheme.cremaLight)
    }

    private func editorField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(CoffeeTheme.mutedText)
            TextField(label, text: text)
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.warmText)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func adjustRemaining(by delta: Double) {
        setRemaining(max(0, remainingWeightG + delta))
    }

    private func setRemaining(_ val: Double) {
        let rounded = (max(0, val) * 10).rounded() / 10
        remainingWeightG = rounded
        remainingText = Self.fmtWeight(rounded)
    }

    private static func fmtWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)
    }

    private static func isoString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private var sheetCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }
}

#if canImport(UIKit)
private struct BeanBagCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: BeanBagCameraPicker
        init(_ parent: BeanBagCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

// MARK: - Add Accessory Sheet

private struct AddAccessorySheet: View {
    let onAdd: (EquipmentItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: String = "布粉压粉"
    @State private var spec: String = ""

    private static let categoryPresets = ["布粉压粉", "称重计时", "萃取手柄", "奶咖工具", "清洁维护", "其他配件"]

    private static let quickPresets: [(name: String, category: String, spec: String)] = [
        ("泰摩电子秤", "称重计时", "0.1g 精度 · 自动计时"),
        ("WDT 布粉针", "布粉压粉", "0.35mm 细针打散结块"),
        ("恒力压粉锤", "布粉压粉", "58mm 自动回弹"),
        ("旋转布粉器", "布粉压粉", "58mm 水平整平"),
        ("磁吸接粉环", "布粉压粉", "58mm 防飞粉"),
        ("无底萃取手柄", "萃取手柄", "58mm 观察通道效应"),
        ("二次分水网", "萃取手柄", "58.5mm 均匀布水"),
        ("丸型滤纸", "萃取手柄", "58mm 粉碗底滤"),
        ("尖嘴拉花缸", "奶咖工具", "450ml 不锈钢"),
        ("桌面小吸尘器", "清洁维护", "清理磨豆残粉"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Quick presets
                    VStack(alignment: .leading, spacing: 10) {
                        Label("常用咖啡角配件一键快填", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CoffeeTheme.cremaLight)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(Self.quickPresets, id: \.name) { preset in
                                Button {
                                    name = preset.name
                                    category = preset.category
                                    spec = preset.spec
                                } label: {
                                    Text(preset.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            name == preset.name ? CoffeeTheme.cremaAccent.opacity(0.24) : CoffeeTheme.cardElevated,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(
                                                    name == preset.name ? CoffeeTheme.cremaAccent : CoffeeTheme.cardBorder,
                                                    lineWidth: 1
                                                )
                                        )
                                        .foregroundStyle(name == preset.name ? CoffeeTheme.cremaAccent : CoffeeTheme.warmText)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(sheetBg)

                    // Form fields
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("配件名称")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.mutedText)
                            TextField("例如：MHW-3BOMBER 恒力压粉锤", text: $name)
                                .font(.subheadline)
                                .foregroundStyle(CoffeeTheme.warmText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(inputBg)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("配件类别")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.mutedText)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Self.categoryPresets, id: \.self) { cat in
                                        Button(cat) {
                                            category = cat
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            category == cat ? CoffeeTheme.cremaAccent : CoffeeTheme.cardElevated,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(category == cat ? CoffeeTheme.espressoBg : CoffeeTheme.warmText)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("规格 / 备注（可选）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CoffeeTheme.mutedText)
                            TextField("例如：58.35mm · 30磅恒力", text: $spec)
                                .font(.subheadline)
                                .foregroundStyle(CoffeeTheme.warmText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(inputBg)
                        }
                    }
                    .padding(14)
                    .background(sheetBg)

                    Button {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let item = EquipmentItem(
                            id: "acc-\(UUID().uuidString.prefix(6).lowercased())",
                            name: trimmed,
                            category: category,
                            spec: spec.trimmingCharacters(in: .whitespacesAndNewlines),
                            role: "日常冲煮配件"
                        )
                        onAdd(item)
                        dismiss()
                    } label: {
                        Label("确认添加到配件清单", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? CoffeeTheme.cardElevated
                                    : CoffeeTheme.cremaAccent,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .foregroundStyle(
                                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? CoffeeTheme.mutedText
                                    : CoffeeTheme.espressoBg
                            )
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .navigationTitle("添加咖啡配件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var sheetBg: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }

    private var inputBg: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CoffeeTheme.cardElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }
}

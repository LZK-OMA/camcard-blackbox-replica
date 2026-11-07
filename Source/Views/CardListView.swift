//
//  CardListView.swift
//  CamCardClone
//
//  名片夹首页：搜索、标签筛选、排序、空态、列表与「扫描名片」悬浮入口。
//

import Foundation
import SwiftUI

struct CardListView: View {

    // MARK: 依赖

    private let store: CardStore
    private let scanPipeline: CardScanPipeline
    private let exporter: ContactExporter
    private let startupWarning: String?

    // MARK: 状态

    /// 列表 ViewModel：同时持有列表数据与「扫描呈现 / 导航路由」交互状态
    /// （这些状态抽到 ViewModel 里，才能被无界面单元测试断言）。
    @State private var viewModel: CardListViewModel

    init(
        store: CardStore,
        scanPipeline: CardScanPipeline,
        exporter: ContactExporter,
        startupWarning: String? = nil
    ) {
        self.store = store
        self.scanPipeline = scanPipeline
        self.exporter = exporter
        self.startupWarning = startupWarning
        _viewModel = State(initialValue: CardListViewModel(store: store))
    }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            NavigationStack(path: $viewModel.route) {
                ZStack(alignment: .bottomTrailing) {
                    // 纯装饰背景：显式关闭命中测试，确保它永远不可能盖住上层卡片/按钮。
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        if let startupWarning {
                            startupWarningBanner(startupWarning)
                        }
                        searchBar(text: $viewModel.query)
                        tagFilterBar
                        if viewModel.isFiltering {
                            resultsSummary
                        }
                        Divider()
                            .opacity(0.35)
                        content
                    }

                    if viewModel.hasAnyCards {
                        scanFloatingButton
                            .zIndex(1)
                    }
                }
                .navigationTitle("名片夹")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
                // 目的地注册在 NavigationStack 的根内容上（而不是塞进 LazyVStack
                // 的每一行里），由值驱动 push，点击只走状态更新。
                // 路由值是纯值类型 CardRoute（==/hash 只用 UUID），
                // 避免 SwiftUI 在转场/属性图更新时访问 SwiftData 模型属性。
                .navigationDestination(for: CardListViewModel.CardRoute.self) { route in
                    CardDetailView(
                        card: route.card,
                        store: store,
                        exporter: exporter
                    )
                }
                .onAppear {
                    // 扫描流程进行中不刷新列表，避免与扫描流程的收尾渲染互相竞争。
                    guard !viewModel.isScannerPresented else { return }
                    // 推迟一个主线程周期再查询，避免在视图更新周期内重入 SwiftData。
                    viewModel.reloadSoon()
                }
                // revision 变化时刷新列表；扫描流程进行中先挂起，
                // 保存成功的同一帧 revision 已自增，等扫描覆盖层移除后再统一刷新，
                // 避免宿主在扫描流程收尾时被重渲染打断。
                .onChange(of: store.revision) { _, _ in
                    guard !viewModel.isScannerPresented else { return }
                    // 同上：数据层查询必须离开 SwiftUI 的更新回调。
                    viewModel.reloadSoon()
                }
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.scheduleReload()
                }
                .refreshable {
                    try? await Task.sleep(for: .milliseconds(400))
                    viewModel.reload()
                }
                .alert(
                    "加载失败",
                    isPresented: Binding(
                        // 扫描流程进行中绝不弹列表的错误 alert，
                        // 避免与扫描流程的呈现/收尾互相打断。
                        get: { !viewModel.isScannerPresented && viewModel.errorMessage != nil },
                        set: { if !$0 { viewModel.errorMessage = nil } }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
            }

            // 扫描流程：视图树内的全屏覆盖层（不是 fullScreenCover）。
            // 绝不能用 UIKit 模态承载 —— 见 scannerOverlay 的注释。
            if viewModel.isScannerPresented {
                scannerOverlay
                    .zIndex(20)
            }
        }
        // 扫描流程收尾（替代原 fullScreenCover 的 onDismiss）：
        // 覆盖层移除后复位一次性参数，并刷新扫描期间挂起的数据变更。
        .onChange(of: viewModel.isScannerPresented) { _, presented in
            guard !presented else { return }
            // 覆盖层已移除：复位一次性参数并刷新扫描期间挂起的数据变更。
            viewModel.reloadAfterScannerDismissal()
        }
    }

    // MARK: - 扫描流程覆盖层

    /// 扫描流程的全屏覆盖层。
    ///
    /// 为什么不用 `fullScreenCover`：
    /// - 扫描页内部自带一个 NavigationStack，保存成功时要先 pop 校对页、
    ///   再关闭整个扫描流程；
    /// - 用 UIKit 模态承载时，这两步会与模态宿主的 dismiss 转场竞争，运行时出现
    ///   `Attempt to present <PresentationHostingController> on <PresentationHostingController>
    ///   ... whose view is not in the window hierarchy`，
    ///   UIKit 的转场协调器被卡住后会留下不可见的呈现层，首页画面正常但所有点击失效
    ///   （CPU 0%、无报错）；
    /// - 改成视图树内的覆盖层后，关闭扫描流程只是移除一个子视图，不经过任何
    ///   模态 present/dismiss，列表的手势链路从头到尾不受影响。
    private var scannerOverlay: some View {
        CardScannerView(
            store: store,
            pipeline: scanPipeline,
            startsWithPhotoPicker: viewModel.startsWithPhotoPicker,
            onRequestClose: {
                // 相机页直接关闭：覆盖层没有压栈的校对页，直接移除即可。
                viewModel.dismissScanner()
            },
            onComplete: { _ in
                // 保存已由 CardStore 完成。这里先让扫描页内部导航栈 pop 校对页，
                // 稍后再移除覆盖层，确保移除时没有进行中的导航转场。
                viewModel.scheduleScannerDismissal()
            }
        )
        // 新会话 → 新身份：相机 / 相册页的 @State 每次从零开始，
        // 保证「从相册导入」每次都能重新拉起系统相册选择流。
        .id(viewModel.scannerSessionID)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - 搜索栏

    private func searchBar(text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("搜索姓名、公司、职位、电话、邮箱", text: text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("搜索名片")

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
        // 搜索胶囊整块（含内边距）都参与命中测试，避免点边缘无反应。
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: text.wrappedValue.isEmpty)
    }

    // MARK: - 标签筛选

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "全部",
                    systemImage: "square.grid.2x2",
                    isSelected: viewModel.isAllTagsSelected
                ) {
                    viewModel.selectAllTags()
                }

                FilterChip(
                    title: "已打标签",
                    systemImage: "tag.fill",
                    isSelected: viewModel.onlyTagged
                ) {
                    viewModel.toggleTaggedFilter()
                }

                if !viewModel.allTags.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 22)
                        .padding(.horizontal, 2)
                }

                ForEach(viewModel.allTags, id: \.self) { tag in
                    FilterChip(
                        title: tag,
                        systemImage: nil,
                        isSelected: viewModel.isTagSelected(tag)
                    ) {
                        viewModel.toggleTag(tag)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 结果摘要

    private var resultsSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption2)
            Text("\(viewModel.rows.count) 条结果")
                .font(.caption2.weight(.medium))
            Spacer()
            Button("清除") {
                viewModel.query = ""
                viewModel.selectAllTags()
                viewModel.reload()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(AppTheme.accent)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    // MARK: - 启动提示

    private func startupWarningBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.09))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.cards.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.rows) { row in
                        // 普通 Button + 状态驱动导航：不再依赖 NavigationLink，
                        // 点击不会被 ScrollView 的滑动识别器吞掉。
                        Button {
                            print("🎯 名片卡片被点击: \(row.title)")
                            viewModel.openDetail(cardID: row.id)
                        } label: {
                            CardListRow(
                                row: row,
                                imageFileManager: store.imageFileManager
                            )
                            // 整张卡片（含全部内边距留白）都是命中区域。
                            .contentShape(Rectangle())
                        }
                        // plain 在 LazyVStack 中命中区域可能退化到文本子视图，
                        // 改用 borderless，保证卡片整块可点。
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .accessibilityHint("打开名片详情")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.emptyStateKind {
        case .noCards:
            noCardsEmptyState
        case .noResults:
            noResultsEmptyState
        case .none:
            EmptyView()
        }
    }

    private var noCardsEmptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                EmptyCardIllustration()
                    .frame(height: 170)
                    .padding(.top, 42)

                VStack(spacing: 8) {
                    Text("还没有名片")
                        .font(.title2.weight(.bold))
                    Text("扫描一张纸质名片，几秒内变成可搜索、可导出的电子联系人。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }

                VStack(spacing: 10) {
                    Button {
                        viewModel.presentScanner(startsWithPhotoPicker: false)
                    } label: {
                        Label("扫描第一张名片", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(AppTheme.accent)

                    Button {
                        viewModel.presentScanner(startsWithPhotoPicker: true)
                    } label: {
                        Label("从相册导入", systemImage: "photo.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                }
                .padding(.horizontal, 34)

                Text("所有数据仅保存在本机，不会上传云端")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var noResultsEmptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(24)
                .background(
                    Circle()
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )

            VStack(spacing: 6) {
                Text("未找到相关名片")
                    .font(.headline)
                Text("试试其他关键词，或清除当前的标签筛选。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("清除筛选") {
                viewModel.query = ""
                viewModel.selectAllTags()
                viewModel.reload()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - 悬浮扫描按钮

    private var scanFloatingButton: some View {
        Button {
            print("📸 扫描悬浮按钮被点击，isScannerPresented 即将被置为 true")
            viewModel.presentScanner(startsWithPhotoPicker: false)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                Text("扫描名片")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.accent,
                                AppTheme.accent.opacity(0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: AppTheme.accent.opacity(0.34), radius: 16, x: 0, y: 8)
            // 渐变 Capsule 自身的填充区域也参与命中测试，圆角边缘不会点空。
            .contentShape(Capsule(style: .continuous))
        }
        // borderless 在自定义背景 + 悬浮层级下命中区域最稳定。
        .buttonStyle(.borderless)
        // 整个胶囊（含阴影外沿留白）都是按钮热区，防止圆角处点击穿透。
        .contentShape(Capsule(style: .continuous))
        .padding(.trailing, 20)
        .padding(.bottom, 22)
        .accessibilityLabel("扫描名片")
        .accessibilityHint("打开相机取景或从相册导入名片")
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            ForEach(CardSort.allCases, id: \.self) { sort in
                Button {
                    viewModel.selectSort(sort)
                } label: {
                    if viewModel.sort == sort {
                        Label(viewModel.sortTitle(for: sort), systemImage: "checkmark")
                    } else {
                        Text(viewModel.sortTitle(for: sort))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityLabel("排序方式")
    }
}

// MARK: - 标签胶囊

private struct FilterChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(AppTheme.accent)
                            : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        // 胶囊整块参与命中测试，点标签文字以外的留白也能切换筛选。
        .contentShape(Capsule(style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 列表卡片

private struct CardListRow: View {
    /// 纯值快照：视图层绝不接触 SwiftData 模型，避免后台属性图更新时触发
    /// SwiftData 的 performAndWait 与 SwiftUI MovableLock 互等死锁。
    let row: CardListViewModel.CardRowSnapshot
    let imageFileManager: CardImageFileManager

    var body: some View {
        HStack(spacing: 14) {
            CardImageView(
                relativePath: row.thumbnailPath,
                imageFileManager: imageFileManager,
                contentMode: .fill,
                maxPixelSize: 420,
                cornerRadius: 12
            )
            .frame(width: 92, height: 66)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let company = row.company,
                   !company.isEmpty,
                   company != row.title {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let jobTitle = row.jobTitle, !jobTitle.isEmpty {
                        Text(jobTitle)
                            .lineLimit(1)
                    }

                    if let primaryNumber = row.primaryNumber {
                        if row.jobTitle?.isEmpty == false {
                            Circle()
                                .fill(Color.secondary.opacity(0.35))
                                .frame(width: 3, height: 3)
                        }
                        Text(primaryNumber)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                if !row.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(row.tags.prefix(2)), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.accent.opacity(0.09))
                                )
                        }

                        if row.tags.count > 2 {
                            Text("+\(row.tags.count - 2)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.035), radius: 10, x: 0, y: 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var components = [row.title]
        if let company = row.company, !company.isEmpty { components.append(company) }
        if let jobTitle = row.jobTitle, !jobTitle.isEmpty { components.append(jobTitle) }
        if let primaryNumber = row.primaryNumber { components.append(primaryNumber) }
        return components.joined(separator: "，")
    }
}

// MARK: - 空态插画

private struct EmptyCardIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.accent.opacity(0.08))
                .frame(width: 236, height: 142)
                .rotationEffect(.degrees(-7))
                .offset(x: 6, y: 4)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .frame(width: 236, height: 142)
                .rotationEffect(.degrees(3))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(AppTheme.accent.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.accent.opacity(0.85),
                                AppTheme.accent.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.9))
                    )

                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Color.primary.opacity(0.16)).frame(width: 92, height: 8)
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 68, height: 6)
                    Capsule().fill(Color.primary.opacity(0.07)).frame(width: 78, height: 6)
                }
            }
            .rotationEffect(.degrees(3))
            .offset(x: 2, y: 0)

            Image(systemName: "viewfinder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.accent)
                .padding(12)
                .background(Circle().fill(Color(uiColor: .systemGroupedBackground)))
                .offset(x: 102, y: -58)
        }
        .accessibilityHidden(true)
    }
}

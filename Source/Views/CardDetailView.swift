//
//  CardDetailView.swift
//  CamCardClone
//
//  名片详情：原图、全部字段、标签增删、备注编辑、删除、系统联动与导出。
//

import SwiftUI
import UIKit

struct CardDetailView: View {

    // MARK: 依赖

    private let store: CardStore
    private let exporter: ContactExporter

    // MARK: 状态

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var viewModel: CardDetailViewModel

    @State private var isShowingEditor = false
    @State private var isShowingImagePreview = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingNotesEditor = false
    @State private var isShowingAddTag = false
    @State private var isShowingOriginalImage = true
    @State private var previewImage: UIImage?
    @State private var isLoadingPreview = false

    init(
        card: BusinessCard,
        store: CardStore,
        exporter: ContactExporter
    ) {
        self.store = store
        self.exporter = exporter
        _viewModel = State(
            initialValue: CardDetailViewModel(
                card: card,
                store: store,
                exporter: exporter
            )
        )
    }

    private var card: BusinessCard { viewModel.card }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: 18) {
                heroImage
                identitySection
                tagSection
                contactSection
                notesSection
                metadataSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("名片详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingEditor = true
                    } label: {
                        Label("编辑字段", systemImage: "square.and.pencil")
                    }

                    Button {
                        _ = viewModel.prepareVCard()
                    } label: {
                        Label("生成 vCard", systemImage: "doc.badge.arrow.up")
                    }

                    Button {
                        Task { await viewModel.saveToContacts() }
                    } label: {
                        Label("导出到联系人", systemImage: "person.crop.circle.badge.plus")
                    }

                    Divider()

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("删除名片", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .sheet(isPresented: $isShowingEditor) {
            NavigationStack {
                CardCorrectionView(
                    mode: .edit(card),
                    store: store
                )
            }
        }
        .sheet(isPresented: $isShowingImagePreview) {
            if let previewImage {
                ImagePreviewSheet(
                    image: previewImage,
                    title: isShowingOriginalImage ? "名片原图" : "名片校正图",
                    onClose: { isShowingImagePreview = false }
                )
            }
        }
        .sheet(isPresented: $isShowingNotesEditor) {
            NotesEditorSheet(initialNotes: card.notes ?? "") { notes in
                if viewModel.saveNotes(notes) {
                    return nil
                }
                return viewModel.errorMessage ?? "备注保存失败"
            }
        }
        .sheet(isPresented: $isShowingAddTag) {
            AddTagSheet { tag in
                viewModel.newTag = tag
                if viewModel.addTag() {
                    return nil
                }
                return viewModel.tagErrorMessage ?? "标签添加失败"
            }
        }
        .sheet(item: $viewModel.sharePayload, onDismiss: {
            viewModel.cleanupExportFiles()
        }) { payload in
            ShareSheet(items: [payload.url]) {
                viewModel.cleanupExportFiles()
            }
        }
        .confirmationDialog(
            "删除这张名片？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if viewModel.deleteCard() {
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名片图片与全部字段将从本机移除，此操作不可恢复。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            if viewModel.requiresContactsSettings {
                Button("去设置") {
                    viewModel.dismissError()
                    viewModel.openSettings()
                }
            }
            Button("好", role: .cancel) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .toast(viewModel.toastMessage)
    }

    // MARK: - 图片

    private var heroImage: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                openImagePreview()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    CardImageView(
                        relativePath: heroPath,
                        imageFileManager: store.imageFileManager,
                        contentMode: .fill,
                        maxPixelSize: 1800,
                        cornerRadius: 22
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 228)

                    if isLoadingPreview {
                        Color.black.opacity(0.22)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("查看大图")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.45))
                    )
                    .padding(12)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看名片大图")

            if card.processedImageFilename != nil {
                HStack(spacing: 2) {
                    imageToggleButton("原图", isOriginal: true)
                    imageToggleButton("校正图", isOriginal: false)
                }
                .padding(3)
                .background(
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.46))
                )
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var heroPath: String {
        if isShowingOriginalImage || card.processedImageFilename == nil {
            return card.originalImageFilename
        }
        return card.processedImageFilename ?? card.originalImageFilename
    }

    private func imageToggleButton(_ title: String, isOriginal: Bool) -> some View {
        Button {
            isShowingOriginalImage = isOriginal
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isShowingOriginalImage == isOriginal
                        ? Color.black.opacity(0.82)
                        : Color.white.opacity(0.82)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isShowingOriginalImage == isOriginal
                                ? Color.white
                                : Color.clear
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isShowingOriginalImage == isOriginal ? .isSelected : [])
    }

    private func openImagePreview() {
        guard !isLoadingPreview else { return }
        isLoadingPreview = true

        Task {
            let image = await CardImageLoader.shared.image(
                relativePath: heroPath,
                using: store.imageFileManager,
                maxPixelSize: 2400
            )
            isLoadingPreview = false
            guard let image else {
                viewModel.showToast("图片文件不可用")
                return
            }
            previewImage = image
            isShowingImagePreview = true
        }
    }

    // MARK: - 身份

    private var identitySection: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(monogram)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.accent,
                                    AppTheme.accent.opacity(0.65)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(card.displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)

                if let company = card.company,
                   !company.isEmpty,
                   company != card.displayTitle {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let jobTitle = card.jobTitle, !jobTitle.isEmpty {
                    Text(jobTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monogram: String {
        let title = card.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.first.map(String.init) ?? "卡"
    }

    // MARK: - 标签

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("标签", systemImage: "tag")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.beginAddingTag()
                    isShowingAddTag = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .accessibilityLabel("添加标签")
            }

            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                if card.tags.isEmpty {
                    Text("暂无标签，添加后可快速筛选")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(card.tags, id: \.self) { tag in
                        HStack(spacing: 6) {
                            Text(tag)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)

                            Button {
                                viewModel.removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除标签 \(tag)")
                        }
                        .foregroundStyle(AppTheme.accent)
                        .padding(.leading, 11)
                        .padding(.trailing, 7)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.accent.opacity(0.09))
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 联系方式

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("联系方式", systemImage: "person.text.rectangle")

            VStack(spacing: 0) {
                ForEach(Array(phoneRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        rowDivider
                    }
                    DetailActionRow(
                        systemImage: row.icon,
                        title: row.title,
                        value: row.value,
                        action: { dial(row.value) },
                        copyAction: { viewModel.copyToPasteboard(row.value, label: row.title) }
                    )
                }

                if let email = card.email, !email.isEmpty {
                    if !phoneRows.isEmpty { rowDivider }
                    DetailActionRow(
                        systemImage: "envelope",
                        title: "邮箱",
                        value: email,
                        action: { sendEmail(email) },
                        copyAction: {
                            viewModel.copyToPasteboard(email, label: "邮箱")
                        }
                    )
                }

                if let website = card.website, !website.isEmpty {
                    if !phoneRows.isEmpty || !(card.email ?? "").isEmpty {
                        rowDivider
                    }
                    DetailActionRow(
                        systemImage: "globe",
                        title: "网址",
                        value: website,
                        action: { openWebsite(website) },
                        copyAction: {
                            viewModel.copyToPasteboard(website, label: "网址")
                        }
                    )
                }

                if let address = card.address, !address.isEmpty {
                    if !phoneRows.isEmpty
                        || !(card.email ?? "").isEmpty
                        || !(card.website ?? "").isEmpty {
                        rowDivider
                    }
                    DetailActionRow(
                        systemImage: "mappin.and.ellipse",
                        title: "地址",
                        value: address,
                        showsOpenAction: false,
                        action: {
                            viewModel.copyToPasteboard(address, label: "地址")
                        },
                        copyAction: {
                            viewModel.copyToPasteboard(address, label: "地址")
                        }
                    )
                }
            }

            if phoneRows.isEmpty,
               (card.email ?? "").isEmpty,
               (card.website ?? "").isEmpty,
               (card.address ?? "").isEmpty {
                Text("暂无联系方式，点击右上角编辑补全。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private struct PhoneRow {
        let icon: String
        let title: String
        let value: String
    }

    private var phoneRows: [PhoneRow] {
        var rows: [PhoneRow] = []
        for number in splitValues(card.mobile) {
            rows.append(PhoneRow(icon: "iphone", title: "手机", value: number))
        }
        for number in splitValues(card.phone) {
            rows.append(PhoneRow(icon: "phone", title: "电话", value: number))
        }
        for number in splitValues(card.fax) {
            rows.append(PhoneRow(icon: "printer", title: "传真", value: number))
        }
        return rows
    }

    private func splitValues(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 备注

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("备注", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingNotesEditor = true
                } label: {
                    Text(card.notes == nil ? "添加" : "编辑")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
            }

            if let notes = card.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("记录跟进信息、见面场景或提醒事项…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 元数据

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("其他信息", systemImage: "info.circle")

            VStack(spacing: 8) {
                metadataLine(title: "来源", value: sourceDescription)
                metadataLine(
                    title: "创建时间",
                    value: card.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                metadataLine(
                    title: "最近修改",
                    value: card.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var sourceDescription: String {
        switch card.source {
        case .camera: return "相机扫描"
        case .photoLibrary: return "相册导入"
        case .file: return "文件导入"
        case .manual: return "手动录入"
        }
    }

    private func metadataLine(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.72))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            detailActionButton(
                title: "编辑",
                systemImage: "square.and.pencil",
                tint: .primary
            ) {
                isShowingEditor = true
            }

            detailActionButton(
                title: "分享 vCard",
                systemImage: "square.and.arrow.up",
                tint: .primary
            ) {
                _ = viewModel.prepareVCard()
            }

            detailActionButton(
                title: "通讯录",
                systemImage: "person.crop.circle.badge.plus",
                tint: AppTheme.accent,
                isLoading: viewModel.isSavingContact
            ) {
                Task { await viewModel.saveToContacts() }
            }

            detailActionButton(
                title: "删除",
                systemImage: "trash",
                tint: .red
            ) {
                isShowingDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    private func detailActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // MARK: - 工具

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.bottom, 10)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 30)
            .opacity(0.4)
    }

    private func dial(_ number: String) {
        guard let url = telephoneURL(number) else {
            viewModel.showToast("号码格式无效")
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            viewModel.copyToPasteboard(number, label: "号码")
            viewModel.showToast("当前设备无法拨号，号码已复制")
            return
        }
        openURL(url)
    }

    private func sendEmail(_ email: String) {
        guard let url = emailURL(email) else {
            viewModel.showToast("邮箱格式无效")
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            viewModel.copyToPasteboard(email, label: "邮箱")
            viewModel.showToast("当前设备无法发送邮件，邮箱已复制")
            return
        }
        openURL(url)
    }

    private func openWebsite(_ website: String) {
        guard let url = URL(string: website) else {
            viewModel.showToast("网址格式无效")
            return
        }
        openURL(url)
    }

    private func telephoneURL(_ number: String) -> URL? {
        let sanitized = String(number.filter { character in
            character.isNumber || "+*#".contains(character)
        })
        guard !sanitized.isEmpty else { return nil }
        return URL(string: "tel://\(sanitized)")
    }

    private func emailURL(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }
}

// MARK: - 详情行

private struct DetailActionRow: View {
    let systemImage: String
    let title: String
    let value: String
    var showsOpenAction: Bool = true
    let action: () -> Void
    let copyAction: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                copyAction()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if showsOpenAction {
                Button(action: action) {
                    Label("打开", systemImage: "arrow.up.right.square")
                }
            }
        }
        .accessibilityLabel("\(title)，\(value)")
    }
}

// MARK: - 标签编辑 Sheet

private struct AddTagSheet: View {

    let onAdd: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("例如：客户 / 展会 / 合作伙伴", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(attemptAdd)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("最多 \(BusinessCard.maxTagLength) 个字符，同名标签自动去重。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(20)
            .navigationTitle("新增标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加", action: attemptAdd)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    private func attemptAdd() {
        if let error = onAdd(text) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

// MARK: - 备注编辑 Sheet

private struct NotesEditorSheet: View {

    let onSave: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var notes: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(initialNotes: String, onSave: @escaping (String) -> String?) {
        self.onSave = onSave
        _notes = State(initialValue: initialNotes)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $notes)
                    .focused($isFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .frame(minHeight: 190)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Text("\(notes.count) / \(BusinessCard.maxNotesLength)")
                        .font(.caption2)
                        .foregroundStyle(
                            notes.count > BusinessCard.maxNotesLength
                                ? Color.red
                                : Color.secondary
                        )
                }
            }
            .padding(16)
            .navigationTitle("编辑备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        if let error = onSave(notes) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(notes.count > BusinessCard.maxNotesLength)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

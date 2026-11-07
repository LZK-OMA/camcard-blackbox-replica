//
//  CardDetailViewModel.swift
//  CamCardClone
//
//  详情页 ViewModel：标签增删、备注保存、删除、vCard 分享与通讯录写入。
//

import Foundation
import Observation
import UIKit

// MARK: - 分享负载

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - ViewModel

@MainActor
@Observable
final class CardDetailViewModel {

    // MARK: 数据

    let card: BusinessCard
    private let store: CardStore
    private let exporter: ContactExporter

    // MARK: 状态

    var errorMessage: String?
    var toastMessage: String?
    var sharePayload: SharePayload?
    var isSavingContact = false
    var requiresContactsSettings = false

    var newTag = ""
    var isAddingTag = false
    var tagErrorMessage: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(card: BusinessCard, store: CardStore, exporter: ContactExporter) {
        self.card = card
        self.store = store
        self.exporter = exporter
    }

    // MARK: - 标签

    func beginAddingTag() {
        newTag = ""
        tagErrorMessage = nil
        isAddingTag = true
    }

    func cancelAddingTag() {
        isAddingTag = false
        newTag = ""
        tagErrorMessage = nil
    }

    @discardableResult
    func addTag() -> Bool {
        do {
            try store.addTag(newTag, to: card)
            isAddingTag = false
            newTag = ""
            tagErrorMessage = nil
            showToast("标签已添加")
            return true
        } catch {
            tagErrorMessage = error.localizedDescription
            return false
        }
    }

    func removeTag(_ tag: String) {
        do {
            try store.removeTag(tag, from: card)
            showToast("标签已删除")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 备注

    @discardableResult
    func saveNotes(_ notes: String) -> Bool {
        do {
            try store.updateNotes(notes, for: card)
            showToast("备注已保存")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 删除

    @discardableResult
    func deleteCard() -> Bool {
        do {
            try store.delete(card)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 导出

    @discardableResult
    func prepareVCard() -> Bool {
        do {
            let url = try exporter.makeVCardFile(for: card)
            sharePayload = SharePayload(url: url)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cleanupExportFiles() {
        exporter.cleanupTemporaryFiles()
    }

    func saveToContacts() async {
        guard !isSavingContact else { return }
        isSavingContact = true
        defer { isSavingContact = false }

        do {
            try await exporter.saveToContacts(card)
            showToast("已导出到系统通讯录")
        } catch ContactExporterError.contactsPermissionDenied {
            requiresContactsSettings = true
            errorMessage = ContactExporterError.contactsPermissionDenied.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 复制 / Toast

    func copyToPasteboard(_ value: String, label: String) {
        UIPasteboard.general.string = value
        showToast("\(label)已复制")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    func dismissError() {
        errorMessage = nil
        requiresContactsSettings = false
    }
}

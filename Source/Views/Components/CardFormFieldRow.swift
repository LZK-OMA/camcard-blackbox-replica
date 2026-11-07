//
//  CardFormFieldRow.swift
//  CamCardClone
//
//  校对 / 编辑页的单行字段。键盘类型、内容类型与清除按钮按字段切换。
//

import SwiftUI
import UIKit

struct CardFormFieldRow: View {

    let field: CardFormField
    @Binding var text: String
    @FocusState.Binding var focusedField: CardFormField?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: field.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? AppTheme.accent : Color.secondary)
                .frame(width: 24, height: 24)
                .padding(.top, 15)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(field.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if field == .name || field == .company {
                        Text("必填其一")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.10))
                            )
                    }
                }

                input
                    .font(.body)
                    .foregroundStyle(.primary)
                    .focused($focusedField, equals: field)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(disablesAutocorrection)
                    .textContentType(contentType)
                    .keyboardType(keyboardType)
                    .submitLabel(field == .address ? .done : .next)
                    .onSubmit(onSubmit)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .accessibilityLabel("清空\(field.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isFocused ? AppTheme.accent.opacity(0.55) : Color.clear,
                    lineWidth: 1.2
                )
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .accessibilityElement(children: .contain)
    }

    private var isFocused: Bool {
        focusedField == field
    }

    @ViewBuilder
    private var input: some View {
        if field == .address {
            TextField(field.placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
        } else {
            TextField(field.placeholder, text: $text)
                .lineLimit(1)
        }
    }

    private var keyboardType: UIKeyboardType {
        switch field {
        case .mobile, .phone:
            return .phonePad
        case .email:
            return .emailAddress
        case .website:
            return .URL
        default:
            return .default
        }
    }

    private var contentType: UITextContentType? {
        switch field {
        case .name: return .name
        case .company: return .organizationName
        case .jobTitle: return .jobTitle
        case .mobile, .phone: return .telephoneNumber
        case .email: return .emailAddress
        case .website: return .URL
        case .address: return .fullStreetAddress
        }
    }

    private var autocapitalization: TextInputAutocapitalization {
        switch field {
        case .name, .company, .jobTitle, .address:
            return .words
        default:
            return .never
        }
    }

    private var disablesAutocorrection: Bool {
        switch field {
        case .email, .website, .mobile, .phone:
            return true
        default:
            return false
        }
    }
}

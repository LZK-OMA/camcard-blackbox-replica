//
//  ToastView.swift
//  CamCardClone
//
//  轻量 toast：保存、复制、通讯录写入等操作反馈。
//

import SwiftUI

struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.82))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Modifier

struct ToastModifier: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                ToastView(message: message)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                    // Toast 只是轻量反馈，绝不允许拦截下层按钮（如「扫描名片」悬浮按钮）。
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: message)
    }
}

extension View {
    func toast(_ message: String?) -> some View {
        modifier(ToastModifier(message: message))
    }
}

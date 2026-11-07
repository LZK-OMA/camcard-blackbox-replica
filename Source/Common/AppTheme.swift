//
//  AppTheme.swift
//  CamCardClone
//
//  集中管理品牌色，避免依赖 Asset Catalog 才能获得统一视觉。
//

import SwiftUI

enum AppTheme {
    /// 主品牌色（深青绿）。
    static let accent = Color(red: 0.05, green: 0.44, blue: 0.42)

    /// 深一档的品牌色，用于渐变收尾。
    static let accentDeep = Color(red: 0.03, green: 0.31, blue: 0.30)

    /// 卡片统一圆角。
    static let cardRadius: CGFloat = 20
}

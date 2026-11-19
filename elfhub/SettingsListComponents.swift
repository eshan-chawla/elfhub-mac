//
//  SettingsListComponents.swift
//  elfhub
//
//  The look of the Settings pages: section headings and plain rows (title,
//  grey description, control on the right) separated by hairline dividers —
//  no boxes. The row views are shared with onboarding, the menu bar panel and
//  Elf pages, where they keep their compact look with an icon; they switch to
//  the list look only when a Settings page sets `usesSettingsListStyle`.
//

import SwiftUI

// MARK: - List style flag

private struct UsesSettingsListStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on the Settings pages: shared rows drop their icon and use the
    /// larger list typography with room between rows for the dividers.
    var usesSettingsListStyle: Bool {
        get { self[UsesSettingsListStyleKey.self] }
        set { self[UsesSettingsListStyleKey.self] = newValue }
    }
}

/// The typography and spacing shared rows use in each style, so every row
/// on a Settings page lines up with the others.
enum SettingsRowMetrics {
    static func titleFont(usesSettingsListStyle: Bool) -> Font {
        usesSettingsListStyle
            ? DS.Typography.interface(size: 13, weight: .regular)
            : DS.Typography.interface(size: 13, weight: .medium)
    }

    static func titleColor(usesSettingsListStyle: Bool) -> Color {
        usesSettingsListStyle ? DS.Colors.textPrimary : DS.Colors.textSecondary
    }

    static func detailFont(usesSettingsListStyle: Bool) -> Font {
        DS.Typography.interface(size: usesSettingsListStyle ? 12 : 11)
    }

    static func detailColor(usesSettingsListStyle: Bool) -> Color {
        usesSettingsListStyle ? DS.Colors.textSecondary : DS.Colors.textTertiary
    }

    static func verticalPadding(usesSettingsListStyle: Bool) -> CGFloat {
        usesSettingsListStyle ? 10 : 4
    }
}

// MARK: - Row icon

/// A shared row's leading icon: shown in the compact look, left out on the
/// Settings pages, where rows are plain text like the rest of the list.
struct SettingsRowIcon: View {
    let systemName: String
    var color: Color = DS.Colors.textTertiary

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        if !usesSettingsListStyle {
            Image(systemName: systemName)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(color)
                .frame(width: 16)
        }
    }
}

// MARK: - Section

/// One group of settings on a page: a heading, an optional line under it,
/// then its rows. Sections are set apart by space, never by a box.
struct SettingsSection<Content: View>: View {
    let title: String
    var caption: String? = nil
    var trailingAccessory: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(DS.Typography.headingSmall)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                if let trailingAccessory {
                    trailingAccessory
                }
            }
            if let caption {
                Text(caption)
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

// MARK: - Divider

/// The hairline between two rows of a section.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// A row that is just a title, a description and a control on the right —
/// for settings whose control isn't a switch (a button, a picker).
struct SettingsLabeledRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: true))
                    .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: true))
                if let detail {
                    Text(detail)
                        .font(SettingsRowMetrics.detailFont(usesSettingsListStyle: true))
                        .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: true))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: true))
    }
}

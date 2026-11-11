//
//  AppearancePickerRow.swift
//  VibeNotch
//
//  Settings row for choosing the app appearance: System / Light / Dark.
//  Uses a compact inline segmented control so it fits in a single row.
//

import SwiftUI

struct AppearancePickerRow: View {
    @AppStorage(AppAppearance.storageKey) private var raw: String = AppAppearance.system.rawValue
    @State private var isHovered = false

    private var selection: AppAppearance {
        AppAppearance(rawValue: raw) ?? .system
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text(L("Appearance"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(AppAppearance.allCases) { option in
                    segment(for: option)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.08))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func segment(for option: AppAppearance) -> some View {
        let isSelected = selection == option
        Button {
            raw = option.rawValue
        } label: {
            Text(L(option.label))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? Theme.panel : .primary.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.9) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var textColor: Color {
        .primary.opacity(isHovered ? 1.0 : 0.7)
    }
}

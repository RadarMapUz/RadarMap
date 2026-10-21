//
//  FamilyTripViews.swift
//  RadarMap
//
//  «Близкие видят прибытие» в поездке (22.1): капсула «Видят: Мама,
//  Дилноза» с паузой на эту поездку и тихая строка «Мама увидит, что вы
//  едете домой» (раз в день, в начале поездки домой).
//

import SwiftUI

/// «Видят: Мама, Дилноза» с паузой — над строкой поездки, пока кому-то видно.
struct FamilyLiveChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let names = liveNames
        if !names.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(FamilyShare.watchersText(names: names))
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(Text(String(format: String(localized: "Время прибытия видят: %@"),
                                                    names.joined(separator: ", "))))
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !Self.showsDemo { env.family.pause() }
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.background, in: Circle())
                        // Кружок 28 pt, мишень 44 (правило 22): пауза — это
                        // касание на ходу, промах — второй взгляд на экран.
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Пауза на эту поездку"))
            }
            // Высоту капсулы задаёт мишень паузы (44), поэтому сверху и
            // снизу — без отступов, а справа кружок отстоит на поля мишени.
            .padding(.leading, 12)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Кому видна поездка; пусто — капсулы нет.
    private var liveNames: [String] {
        let names = env.family.liveNames
        if !names.isEmpty { return names }
        return Self.showsDemo ? ["Мама", "Dilnoza opa"] : []
    }

    /// Скриншот-хук `-demoFamilyLive` (DEBUG): имена в капсуле без живой
    /// ссылки. Сама капсула — только в поездке (`radarmap://start-trip`).
    static var showsDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoFamilyLive")
        #else
        false
        #endif
    }
}

/// «Мама увидит, что вы едете домой» — тихо, под HUD, на несколько секунд.
/// VoiceOver проговаривает её: незрячий водитель тоже должен знать, кому
/// видно.
struct FamilyNoticeChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let text = env.family.notice ?? (env.location.isTripActive ? Self.demoText : nil) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .font(.rounded(12, .bold))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.rounded(12, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .onAppear {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    /// Скриншот-хук `-demoFamilyNotice` (DEBUG) — как и настоящая строка,
    /// только в поездке.
    private static var demoText: String? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoFamilyNotice")
            ? FamilyShare.noticeText(names: ["Мама"]) : nil
        #else
        nil
        #endif
    }
}

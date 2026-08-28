//
//  MapLayersControl.swift
//  RadarMap
//
//  Слои карты — ОДНА панель, доступная в любом режиме.
//
//  До неё было две. Подложка (Apple / своя схема / движок) выбиралась двумя
//  тумблерами в десятом разделе настроек и вступала в силу только после старта
//  поездки: четыре тапа, прокрутка мимо девяти разделов и обязательная
//  поездка, чтобы увидеть результат. А слои подложки (пробки, места) жили в
//  своей панели, которая показывалась ТОЛЬКО на стоянке, — то есть в поездке
//  пробки нельзя было включить ничем.
//
//  Замерено у соседей: у Google, Apple, Яндекса и 2ГИС смена слоя — два
//  касания, и результат виден до закрытия панели. Здесь так же.
//
//  Свёрнутая кнопка показывает ВЫБРАННУЮ подложку, а не абстрактные «слои»:
//  состояние читается, не открывая панель.
//

import SwiftUI

struct MapLayersControl: View {
    @Binding var base: MapBase
    @Binding var traffic: Bool
    @Binding var places: Bool
    /// Какие подложки есть в этой сборке (движка может не быть).
    var available: [MapBase]
    /// Легенда типов камер — только там, где эти маркеры и рисуются.
    var showsLegend: Bool

    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isExpanded { panel }
            CircleControl(systemName: base.symbol,
                          tint: isExpanded ? Theme.accent : Theme.textPrimary,
                          size: 44,
                          accessibilityLabel: "Слои карты") {
                isExpanded.toggle()
                postpone()
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.16), value: isExpanded)
        .onDisappear { collapseTask?.cancel() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Карта")
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            ForEach(available) { option in
                baseRow(option)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)

            toggle("Пробки", "car.2.fill", isOn: $traffic)
            toggle("Места", "fuelpump.fill", isOn: $places)

            if showsLegend {
                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)
                LegendChip(color: Theme.Types.camera, symbol: "camera.fill", text: "Камера")
                LegendChip(color: Theme.Types.radar, symbol: "speedometer", text: "Радар")
                LegendChip(color: Theme.Types.intelligent, symbol: "camera.metering.matrix",
                           text: "Интеллект.")
                LegendChip(color: Theme.Types.mobile, symbol: "dot.radiowaves.left.and.right",
                           text: "Передвижной")
            }
        }
        .padding(12)
        .frame(width: 208, alignment: .leading)
        .background(Theme.background.opacity(0.42),
                    in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
    }

    /// Строка подложки. Выбранная обведена акцентом: за рулём это читается
    /// быстрее подписи и не заставляет сравнивать три значка между собой.
    private func baseRow(_ option: MapBase) -> some View {
        Button {
            if option != base {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                base = option
            }
            // Панель НЕ закрывается на выборе, и это не мелочь: подложки
            // сравнивают на одном и том же месте, переключая туда-сюда. Панель,
            // захлопывающаяся после каждого выбора, требует двух тапов на
            // каждое сравнение. Закроется сама.
            postpone()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: option.symbol)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(option == base ? Theme.accent : Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(option == base ? Theme.accent.opacity(0.14) : .clear,
                                in: Circle())
                Text(option.title)
                    .font(.rounded(13, option == base ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                if option == base {
                    Image(systemName: "checkmark")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            // Мишень до 44 пунктов: строка остаётся тонкой, растёт только
            // область касания — отсюда padding ДО contentShape.
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(option == base ? [.isSelected, .isButton] : .isButton)
    }

    private func toggle(_ title: LocalizedStringKey, _ icon: String,
                        isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            postpone()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
                    .frame(width: 26)
                Text(title)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 10)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.rounded(14))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Панель закрывается сама: открытой она занимает четверть экрана, а
    /// водитель, отвлёкшийся после нажатия, закрывать её не станет.
    private func postpone() {
        collapseTask?.cancel()
        guard isExpanded else { return }
        collapseTask = Task {
            await Task.pause(seconds: 6)
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }
}

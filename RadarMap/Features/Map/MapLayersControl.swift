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
    /// Дома и тротуары своей схемы. Отдельными тумблерами, а не «подробнее»
    /// одной ручкой: платят за них по-разному (дома — 78 МБ из 347 по стране,
    /// тротуары — один), и нужны они разным людям.
    @Binding var houses: Bool
    @Binding var sidewalks: Bool
    /// Новая карта (бета) — основа OpenMapTiles вместо прежнего стиля движка.
    @Binding var modern: Bool
    /// Тумблеры застройки показываются там, где они что-то меняют: на карте
    /// Apple ни домов наших, ни тротуаров нет.
    var showsBuildingLayers: Bool
    /// Какие подложки есть в этой сборке (движка может не быть).
    var available: [MapBase]
    /// Легенда типов камер — только там, где эти маркеры и рисуются.
    var showsLegend: Bool
    /// Сколько панели можно занять по высоте — до нижних панелей экрана.
    /// Не влезает — листается, а не уезжает под них.
    var maxPanelHeight: CGFloat = .infinity

    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    /// Настоящая высота содержимого панели — мерится внутри ScrollView.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Панель открывается СБОКУ от кнопки, поверх карты, и в вёрстке
        // колонки не участвует. Раньше она вставала в колонку над кнопкой —
        // 208×~350 pt — и сталкивала вниз все кнопки под собой, на маленьком
        // iPhone за край экрана и под нижние панели.
        CircleControl(systemName: base.symbol,
                      tint: isExpanded ? Theme.accent : Theme.textPrimary,
                      accessibilityLabel: "Слои карты") {
            isExpanded.toggle()
            postpone()
        }
        .overlay(alignment: .topTrailing) {
            if isExpanded {
                panel
                    .offset(x: -(Theme.controlSize + 10))
            }
        }
        .motionAnimation(.spring(duration: 0.32, bounce: 0.16), value: isExpanded)
        .onDisappear { collapseTask?.cancel() }
    }

    private var panel: some View {
        ScrollView {
            panelContent
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 208,
               height: contentHeight > 0 ? min(contentHeight, max(maxPanelHeight, Theme.controlSize)) : nil)
        .background(Theme.background.opacity(0.42),
                    in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
        .liftPanel()
        .transition(.scale(scale: 0.86, anchor: .topTrailing).combined(with: .opacity))
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Карта")
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            ForEach(available) { option in
                baseRow(option)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)

            // Пробки — только у Apple (своего источника нет); «Места» — на
            // любой подложке: на новой карте прячут кафе и банки, а заправки
            // и парковки остаются всегда.
            if base == .apple {
                toggle("Пробки", "car.2.fill", isOn: $traffic)
            }
            toggle("Места", "fuelpump.fill", isOn: $places)

            if showsBuildingLayers {
                toggle("Новая карта (бета)", "sparkles", isOn: $modern)
                toggle("Дома", "building.2.fill", isOn: $houses)
                // Тротуары рисует и движок (SketchPalette.sidewalkTone в стиле),
                // так что тумблер больше не привязан к снятой подложке.
                toggle("Тротуары", "figure.walk", isOn: $sidewalks)
            }

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
            // Мишень 44 пункта: строка остаётся тонкой, растёт только
            // область касания — отсюда высота ДО contentShape.
            .frame(minHeight: Theme.controlSize)
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
            .frame(minHeight: Theme.controlSize)
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

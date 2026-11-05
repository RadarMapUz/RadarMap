//
//  SharePreviewSheet.swift
//  RadarMap
//
//  Предпросмотр карточки перед отправкой.
//
//  Раньше тап по «поделиться» рендерил картинку и сразу открывал системный
//  шит: человек отправлял вслепую, а увидеть, что именно ушло, мог только у
//  собеседника. Здесь он сначала смотрит, потом выбирает формат — лента (4:5)
//  или сторис (9:16), — и только затем делится.
//
//  Рендер идёт по требованию и только для выбранного формата: две картинки
//  «на всякий случай» — это две лишние отрисовки карты в память ради кадра,
//  который, возможно, не понадобится.
//

import SwiftUI

/// Что рисуем. Карточки собираются здесь, а не передаются готовым `View`:
/// формат меняется по тапу, и пересобрать нужно именно содержимое.
enum ShareSubject {
    case trip(TripRecord, map: UIImage?)
    case period(PeriodSummary, title: String, map: UIImage?)
    case achievement(Achievement, lifetime: LifetimeStats)
}

/// Обёртка для `.sheet(item:)`: сам ShareSubject не Identifiable и не должен
/// им быть — идентичность здесь у показа, а не у темы.
struct ShareSubjectBox: Identifiable {
    let id = UUID()
    let subject: ShareSubject
}

struct SharePreviewSheet: View {
    let subject: ShareSubject
    @Environment(\.dismiss) private var dismiss

    @State private var format: ShareFormat = .feed
    @State private var image: UIImage?
    @State private var payload: ShareImagePayload?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                formatPicker
                shareButton
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .navigationTitle("Поделиться")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Готово» — справа, как во всех остальных листах приложения.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Первый рендер и перерисовка на смену формата — одним путём.
        .task(id: format) { image = await render() }
        .sheet(item: $payload) { item in
            ActivityShareSheet(image: item.image)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
        } else {
            // Место под картинку держим заранее: без этого экран прыгает,
            // когда рендер заканчивается.
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .fill(Theme.surface)
                .overlay(ProgressView().tint(Theme.accent))
                .aspectRatio(format.size.width / format.size.height, contentMode: .fit)
                .frame(maxHeight: .infinity)
        }
    }

    private var formatPicker: some View {
        HStack(spacing: 8) {
            ForEach(ShareFormat.allCases) { item in
                let selected = format == item
                Button {
                    withMotion(Motion.quick) { format = item }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.rounded(14, .semibold))
                        // Выбранный формат — синяя заливка с белым: состояние,
                        // а не действие. Действие на экране одно — жёлтое
                        // «Поделиться» ниже; раньше обе плашки были одного
                        // синего, и выбор формата читался второй главной кнопкой.
                        .foregroundStyle(selected ? Theme.onAccentFill : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(selected ? AnyShapeStyle(Theme.accentFill)
                                             : AnyShapeStyle(Theme.surface),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(.choice))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// Единственное главное действие экрана — общий жёлтый `PrimaryButton`,
    /// а не самодельная синяя капсула того же цвета, что выбранный формат.
    private var shareButton: some View {
        PrimaryButton(title: "Поделиться", systemImage: "square.and.arrow.up") {
            guard let image else { return }
            payload = ShareImagePayload(image: image)
        }
        .disabled(image == nil)
        .opacity(image == nil ? 0.5 : 1)
    }

    /// Отрисовка выбранной карточки. `@MainActor` неявно (весь тип на нём):
    /// ImageRenderer работает только на главном, поэтому «вне main» здесь
    /// не бывает — зато рендерим ровно один формат и ровно по требованию.
    private func render() async -> UIImage? {
        let renderer: ImageRenderer<AnyView>
        switch subject {
        case .trip(let record, let map):
            renderer = ImageRenderer(content: AnyView(
                TripShareCard(record: record, mapImage: map, format: format)))
        case .period(let summary, let title, let map):
            renderer = ImageRenderer(content: AnyView(
                PeriodShareCard(summary: summary, periodTitle: title,
                                mapImage: map, format: format)))
        case .achievement(let badge, let lifetime):
            renderer = ImageRenderer(content: AnyView(
                AchievementShareCard(badge: badge, lifetime: lifetime, format: format)))
        }
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(format.size)
        return renderer.uiImage
    }
}

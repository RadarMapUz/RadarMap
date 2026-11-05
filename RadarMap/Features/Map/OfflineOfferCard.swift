//
//  OfflineOfferCard.swift
//  RadarMap
//
//  Разовое предложение «Карта области без интернета» внизу главного экрана.
//  Когда показывать — решает чистый OfflineOffer; здесь только вид и ответ.
//  Любой ответ запоминается навсегда: второй раз приложение не спросит,
//  скачать можно в Настройки → Карта → Офлайн-карты.
//

import SwiftUI

struct OfflineOfferCard: View {
    @Environment(AppEnvironment.self) private var env
    /// Карта на экране — наша (на карте Apple офлайн-файлы ничего не дают).
    let ownMap: Bool
    /// Ответ — локально, чтобы карточка ушла сразу: Storage не наблюдаемый.
    @State private var answered = Storage.bool(.offlineOfferAnswered)
    #if DEBUG
    /// Ответ на демо-карточку: только на этот запуск, в Storage не пишется.
    @State private var demoAnswered = false
    #endif

    var body: some View {
        if let region = offeredRegion {
            // Одной строкой — только если она помещается целиком, без
            // обрезки; иначе две: заголовок во всю ширину, «Скачать» ниже.
            // На SE строка не помещалась уже на обычном кегле («Карта без
            // и… / Ташкент · 20,…»), а на узбекском крупном от заголовка
            // оставалось «Int… / Tos…» (14.9): справа мишень крестика 44 pt
            // и кнопка, которой ужиматься нельзя.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    icon
                    texts(region, wraps: false)
                    Spacer(minLength: 0)
                    closeButton
                    downloadButton(region)
                }
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        texts(region, wraps: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        closeButton
                    }
                    downloadButton(region)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liftedBackground(Theme.surface,
                              in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    /// Знак карточки — украшение: что предлагают, говорит заголовок.
    private var icon: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.rounded(18, .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 36, height: 36)
            .background(Theme.quietFill, in: Circle())
            .accessibilityHidden(true)
    }

    /// Заголовок и «Ташкент · 20 МБ». В строке — по одной строке каждому
    /// (переносом «Скачать» справа ломалось на «Скачат / ь», 16e, 13.10);
    /// в две строки карточки — с переносом: места по ширине там вся карточка.
    @ViewBuilder
    private func texts(_ region: RegionCatalog.Region, wraps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Карта без интернета")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(wraps ? nil : 1)
                .minimumScaleFactor(wraps ? 1 : 0.85)
                .fixedSize(horizontal: false, vertical: wraps)
            Text(region.title(language: OfflineMapsView.language(env.settings.appLanguage))
                 + " · " + OfflineMapsView.size(region.totalBytes))
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }

    /// «Не сейчас» — крестиком: словом оно отнимало у заголовка место на
    /// 4,7" («Карта без и…», 16e, 13.10).
    private var closeButton: some View {
        Button {
            answer()
        } label: {
            Image(systemName: "xmark")
                .font(.rounded(14, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.textTertiary.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .tapTarget()
        .accessibilityLabel(Text("Не сейчас"))
    }

    private func downloadButton(_ region: RegionCatalog.Region) -> some View {
        Button {
            // Демо-карточка ничего не качает: снимок, а не загрузка.
            if !Self.showsDemo { env.offlineMaps.download(region) }
            answer()
        } label: {
            // Синяя, не жёлтая: жёлтая на экране одна — главное действие
            // («Начать поездку» рядом). Высота — мишень 44.
            Text("Скачать")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.onAccentFill)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.controlSize)
                .background(Theme.accentFill, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// Область, которую стоит предложить, — или nil, если момент не тот.
    private var offeredRegion: RegionCatalog.Region? {
        let service = env.offlineMaps
        let anchor = OfflineOffer.anchor(
            home: env.settings.homePlace?.coordinate,
            learnedHome: env.learnedPlaces.first { $0.kind == .home }?.coordinate,
            current: env.location.currentCoordinate)
        let region = service.region(containing: anchor)
        #if DEBUG
        // Скриншот-хук `-demoOfflineOffer`: карточка мимо «уже ответили» и
        // «спокойного момента» — область из настоящего каталога.
        if Self.showsDemo {
            return demoAnswered ? nil : region ?? service.catalog?.regions.first
        }
        #endif
        let available = region.map { service.state(for: $0) == .notDownloaded } ?? false
        var situation = OfflineOffer.Situation(
            onboarded: Storage.bool(.hasCompletedOnboarding),
            answered: answered,
            ownMap: ownMap,
            driving: env.location.isTripActive || env.location.isProbablyDriving,
            online: env.network.isOnline,
            expensiveNetwork: env.network.isExpensive,
            regionAvailable: available)
        guard OfflineOffer.shouldOffer(situation) else { return nil }
        // Догадка «Домой» считается, только если иначе предложили бы: вопрос
        // почти всегда уже отвечен, а тело перерисовывается на фиксах.
        situation.suggestionShown = IdleDock.guess(env) != nil
        return OfflineOffer.shouldOffer(situation) ? region : nil
    }

    private func answer() {
        #if DEBUG
        if Self.showsDemo {
            withMotion(Motion.standard) { demoAnswered = true }
            return
        }
        #endif
        Storage.set(true, for: .offlineOfferAnswered)
        withMotion(Motion.standard) { answered = true }
    }

    /// Скриншот-хук `-demoOfflineOffer` (DEBUG).
    static var showsDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoOfflineOffer")
        #else
        false
        #endif
    }
}

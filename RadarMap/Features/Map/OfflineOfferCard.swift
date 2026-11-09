//
//  OfflineOfferCard.swift
//  RadarMap
//
//  Предложение «Карта без интернета» внизу главного экрана — по разу на
//  область. Когда показывать — решает чистый OfflineOffer; здесь вид и ответ.
//  Любой ответ запоминается для этой области. После «Скачать» карточка
//  показывает ход и обрыв с «Повторить»: иначе человек не узнал бы, что карта
//  не скачалась, — в настройки за этим никто не ходит.
//

import SwiftUI

struct OfflineOfferCard: View {
    @Environment(AppEnvironment.self) private var env
    /// Карта на экране — наша (на карте Apple офлайн-файлы ничего не дают).
    let ownMap: Bool
    /// Ответы — локально, чтобы карточка ушла сразу: Storage не наблюдаемый.
    @State private var answeredRegions = OfflineOffer.decodeRegions(Storage.string(.offlineOfferRegions))
    #if DEBUG
    /// Ответ на демо-карточку: только на этот запуск, в Storage не пишется.
    @State private var demoAnswered = false
    #endif

    private enum Offer {
        case ask(RegionCatalog.Region)
        case downloading(RegionCatalog.Region, Double)
        case failed(RegionCatalog.Region, String)
    }

    var body: some View {
        if let offer {
            content(offer)
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

    @ViewBuilder
    private func content(_ offer: Offer) -> some View {
        switch offer {
        case .ask(let region):
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
                    closeButton(region)
                    downloadButton(region)
                }
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        texts(region, wraps: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        closeButton(region)
                    }
                    downloadButton(region)
                }
            }
        case .downloading(let region, let fraction):
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text("Скачиваем карту")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    ProgressView(value: fraction)
                        .tint(Theme.accent)
                    Text(regionTitle(region) + " · \(Int(fraction * 100)) %")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                closeButton(region)
            }
        case .failed(let region, let message):
            VStack(alignment: .trailing, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Карта не скачалась")
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(regionTitle(region) + " · " + message)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    closeButton(region)
                }
                actionButton(String(localized: "Повторить")) { env.offlineMaps.download(region) }
            }
        }
    }

    private func regionTitle(_ region: RegionCatalog.Region) -> String {
        region.title(language: OfflineMapsView.language(env.settings.appLanguage))
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
            Text(regionTitle(region) + " · " + OfflineMapsView.size(region.totalBytes))
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }

    /// «Не сейчас» — крестиком: словом оно отнимало у заголовка место на
    /// 4,7" («Карта без и…», 16e, 13.10).
    private func closeButton(_ region: RegionCatalog.Region) -> some View {
        Button {
            decline(region)
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
        actionButton(String(localized: "Скачать")) {
            // Демо-карточка ничего не качает: снимок, а не загрузка.
            guard !Self.showsDemo else { return decline(region) }
            remember(region.id)
            env.offlineMaps.download(region)
        }
    }

    /// Синяя, не жёлтая: жёлтая на экране одна — главное действие
    /// («Начать поездку» рядом). Высота — мишень 44.
    private func actionButton(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(verbatim: title)
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.onAccentFill)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.controlSize)
                .background(Theme.accentFill, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var offer: Offer? {
        let service = env.offlineMaps
        #if DEBUG
        // Скриншот-хук `-demoOfflineOffer`: карточка мимо «уже ответили» и
        // «спокойного момента» — область из настоящего каталога.
        if Self.showsDemo {
            let anchor = OfflineOffer.offerPoint(
                current: env.location.currentCoordinate,
                home: env.settings.homePlace?.coordinate,
                learnedHome: env.learnedPlaces.first { $0.kind == .home }?.coordinate)
            return demoAnswered ? nil : (service.region(containing: anchor) ?? service.catalog?.regions.first).map(Offer.ask)
        }
        #endif
        // За рулём координату не читаем: иначе тело пересобиралось бы на
        // каждом фиксе ради вопроса, который на ходу не задают.
        guard !(env.location.isTripActive || env.location.isProbablyDriving) else { return nil }
        let home = env.settings.homePlace?.coordinate
        let learnedHome = env.learnedPlaces.first { $0.kind == .home }?.coordinate
        guard let region = service.region(containing: OfflineOffer.offerPoint(
            current: env.location.currentCoordinate, home: home, learnedHome: learnedHome)) else { return nil }
        switch service.state(for: region) {
        case .downloading(let fraction): return .downloading(region, fraction)
        case .failed(let message): return .failed(region, message)
        case .ready, .updateAvailable: return nil
        case .notDownloaded:
            return shouldAsk(region, homeRegionID: service.region(containing: home ?? learnedHome)?.id)
                ? .ask(region) : nil
        }
    }

    /// Стоит ли спрашивать про область, ещё не скачанную, в этот момент.
    private func shouldAsk(_ region: RegionCatalog.Region, homeRegionID: String?) -> Bool {
        var situation = OfflineOffer.Situation(
            onboarded: Storage.bool(.hasCompletedOnboarding),
            answered: OfflineOffer.wasAnswered(
                regionID: region.id, answeredRegions: answeredRegions,
                legacyAnswered: Storage.bool(.offlineOfferAnswered), homeRegionID: homeRegionID),
            ownMap: ownMap,
            driving: false,
            online: env.network.isOnline,
            expensiveNetwork: env.network.isExpensive,
            constrainedNetwork: env.network.isConstrained,
            regionBytes: region.totalBytes,
            regionAvailable: true)
        guard OfflineOffer.shouldOffer(situation) else { return false }
        // Догадка «Домой» считается, только если иначе предложили бы: вопрос
        // почти всегда уже отвечен, а тело перерисовывается на фиксах.
        situation.suggestionShown = IdleDock.guess(env) != nil
        return OfflineOffer.shouldOffer(situation)
    }

    /// «Не сейчас» или ✕ у идущей загрузки: снять её и не спрашивать больше
    /// об этой области.
    private func decline(_ region: RegionCatalog.Region) {
        #if DEBUG
        if Self.showsDemo {
            withMotion(Motion.standard) { demoAnswered = true }
            return
        }
        #endif
        // Не установлена: delete отменит загрузку и сотрёт ошибку.
        env.offlineMaps.delete(region)
        withMotion(Motion.standard) { remember(region.id) }
    }

    private func remember(_ id: String) {
        answeredRegions.insert(id)
        Storage.set(OfflineOffer.encodeRegions(answeredRegions), for: .offlineOfferRegions)
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

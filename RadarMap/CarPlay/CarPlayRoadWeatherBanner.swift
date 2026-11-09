//
//  CarPlayRoadWeatherBanner.swift
//  RadarMap
//
//  «Перевал Камчик — туман, через 32 км» на экране машины (19.2).
//
//  Тот же `RoadWeatherService.banner`, что карточка на телефоне, — баннером
//  навигатора в общей очереди (CarPlayBanners): ниже камеры, объезда и
//  запроса водителя. Вытесненный камерой баннер вернётся, когда экран
//  освободится, если его время ещё не вышло; закрытый водителем или
//  истёкший — нет. «Понятно» в машине снимает и карточку на телефоне.
//

import CarPlay
import os

@MainActor
final class CarPlayRoadWeatherBanner {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private var alert: CPNavigationAlert?
    /// Какой баннер сервиса показан (или уже был показан и закрыт).
    private var shownID: Int?

    func sync(_ banner: RoadWeatherService.Banner?, banners: CarPlayBanners, onDark: Bool,
              now: Date = Date()) {
        if let shownID, banner?.id != shownID {
            // Погасло на телефоне или пришло другое: своё снимаем, новое
            // заменит прежнее само (show) — два снятия подряд CarPlay мог бы
            // сложить так, что новое не встало бы.
            let shown = alert
            alert = nil
            self.shownID = nil
            if banner == nil, let shown { banners.dismiss(shown) }
        }
        guard let banner, shownID == nil else { return }
        // Осталось меньше пары секунд — не показываем: мелькнувший баннер
        // за рулём хуже, чем никакого (голос уже сказал).
        let remaining = banner.until.timeIntervalSince(now)
        guard remaining >= AppConfig.carPlayRoadWeatherMinSeconds else { return }
        let notice = banner.notice
        let next = CPNavigationAlert(
            titleVariants: [notice.headline, notice.title],
            subtitleVariants: [notice.distanceLine],
            image: CarPlayGuidance.symbol(notice.symbol, pointSize: 30, onDark: onDark),
            primaryAction: CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in
                AppEnvironment.shared.roadWeather.hideBanner()
            },
            secondaryAction: nil,
            duration: remaining)
        guard banners.show(next, kind: .roadWeather) else { return }
        alert = next
        shownID = banner.id
        Log.carplay.notice("погода на перевале: баннер в машине (\(notice.pointID, privacy: .public))")
    }

    /// Снят системой (вытеснен камерой): вернётся на `onIdle`, если ещё не истёк.
    func forget(_ alert: CPNavigationAlert) {
        guard alert === self.alert else { return }
        self.alert = nil
        shownID = nil
    }

    /// Подключение кончилось.
    func reset() {
        alert = nil
        shownID = nil
    }
}

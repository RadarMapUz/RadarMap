//
//  CarPlayJamBanner.swift
//  RadarMap
//
//  «Пробка впереди: задержка 6 мин» на экране машины (27.E).
//
//  До 27.E пробка без маршрута (JamAhead) была только голосом: с выключенным
//  голосом или под музыкой в машине о ней не узнавал никто, хотя экран
//  CarPlay — ровно то, на что за рулём смотрят. Тот же `AppEnvironment
//  .jamNotice`, баннером навигатора в общей очереди (CarPlayBanners): ниже
//  камеры, объезда и запроса водителя, выше погоды на перевале. Вытесненный
//  камерой вернётся, когда экран освободится, если его время ещё не вышло;
//  закрытый водителем («Понятно») или истёкший — нет.
//
//  Только картинка: на оповещения о камерах не влияет (правило 20).
//

import CarPlay
import os

@MainActor
final class CarPlayJamBanner {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private var alert: CPNavigationAlert?
    /// Какая пробка показана (или уже была показана и закрыта).
    private var shownID: Int?

    func sync(_ notice: JamAhead.Notice?, banners: CarPlayBanners, onDark: Bool, now: Date = Date()) {
        if let shownID, notice?.id != shownID {
            // Пришла другая пробка: новая заменит прежнюю сама (show) — два
            // снятия подряд CarPlay мог бы сложить так, что новая не встала бы.
            let shown = alert
            alert = nil
            self.shownID = nil
            if notice == nil, let shown { banners.dismiss(shown) }
        }
        guard let notice, shownID == nil, notice.isShowable(now: now) else { return }
        let next = CPNavigationAlert(
            titleVariants: [notice.jam.bannerTitle],
            subtitleVariants: [notice.jam.bannerSubtitle],
            image: CarPlayGuidance.symbol("car.2.fill", pointSize: 30, onDark: onDark),
            primaryAction: CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in },
            secondaryAction: nil,
            duration: notice.until.timeIntervalSince(now))
        guard banners.show(next, kind: .jam) else { return }
        alert = next
        shownID = notice.id
        Log.carplay.notice("пробка впереди: баннер в машине, +\(Int(notice.jam.delay), privacy: .public) с")
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

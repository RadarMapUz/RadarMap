//
//  MapScreen+Hints.swift
//  RadarMap
//
//  Главный экран: однократные подсказки, «что нового», совет про экран при низком заряде.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension MapScreen {

    // MARK: - «Что нового»

    /// Один раз на выпуск текста, только стоя и без машины (WhatsNew). Выпуск
    /// помечается увиденным при показе: убитое на открытом листе приложение
    /// не покажет его второй раз.
    func maybeShowWhatsNew() -> Bool {
        guard WhatsNew.shouldShow(seenEdition: Storage.int(.whatsNewEdition),
                                  onboarded: Storage.bool(.hasCompletedOnboarding),
                                  isDriving: env.location.isTripActive || env.location.isProbablyDriving,
                                  carPlay: env.isCarPlayConnected),
              !map.showStats, !map.showSettings, !map.showSearch, !showMyPlaces
        else { return false }
        Storage.set(WhatsNew.edition, for: .whatsNewEdition)
        hintConsumedThisLaunch = true
        showsWhatsNew = true
        return true
    }

    // MARK: - Разовые подсказки

    /// Показать следующую невиданную подсказку (максимум одну за запуск).
    /// Решение «какую» — чистый OneTimeHints; здесь только Storage и таймер.
    func maybeShowHint() {
        guard Storage.bool(.hasCompletedOnboarding), !hintConsumedThisLaunch,
              activeHint == nil, !map.isAddingCamera else { return }
        var shown: Set<OneTimeHints.Hint> = []
        if Storage.bool(.hintTogglesShown) { shown.insert(.toggles) }
        if Storage.bool(.hintRadarShown) { shown.insert(.radar) }
        if Storage.bool(.hintSilenceShown) { shown.insert(.smartSilence) }
        if Storage.bool(.hintCarOnlyShown) { shown.insert(.carOnlyOffer) }
        guard let hint = OneTimeHints.next(
            shown: shown,
            radarVisible: mode.showsReportButton,
            hasDriven: env.trip.lifetime.trips > 0 || env.location.isTripActive,
            hasFamiliarCameras: !env.location.familiarCameraIDs.isEmpty,
            // Не за рулём: подсказка ведёт в настройки.
            offersCarOnly: env.offersCarOnlyMode && !env.location.isTripActive
                && !env.isCarPlayConnected) else { return }
        hintConsumedThisLaunch = true
        switch hint {
        case .toggles:   Storage.set(true, for: .hintTogglesShown)
        case .radar:     Storage.set(true, for: .hintRadarShown)
        case .smartSilence: Storage.set(true, for: .hintSilenceShown)
        case .carOnlyOffer: Storage.set(true, for: .hintCarOnlyShown)
        }
        withMotion(Motion.standard) { activeHint = hint }
        Task {
            await Task.pause(seconds: 7)
            withMotion(.easeOut(duration: 0.3)) { activeHint = nil }
        }
    }

    /// «Батарея садится — погасите экран»: поездка началась, зарядки нет,
    /// батарея ниже трети. Раньше здесь звали в спидометр; его нет, а честный
    /// совет один — экран и есть главный потребитель, и гасить его можно:
    /// поездка, начатая на экране, звучит и с погашенным — и при «Всегда», и
    /// при «При использовании» (S2, 20.10). Без доступа вовсе совета нет.
    /// Мониторинг батареи включается на один замер и тут же гасится — держать
    /// его постоянно ради подсказки было бы иронией на тему экономии.
    func maybeSuggestScreenOffForBattery() {
        guard [.authorizedAlways, .authorizedWhenInUse].contains(env.location.authorizationStatus) else { return }
        let battery = BatteryProbe.snapshot()
        guard let percent = battery.percent, percent < 30, !battery.isCharging else { return }
        withMotion(Motion.standard) { showBatterySaverHint = true }
        Task {
            await Task.pause(seconds: 8)
            withMotion(.easeOut(duration: 0.3)) { showBatterySaverHint = false }
        }
    }
}

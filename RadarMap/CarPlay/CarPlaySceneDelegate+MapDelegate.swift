//
//  CarPlaySceneDelegate+MapDelegate.swift
//  RadarMap
//
//  CPMapTemplateDelegate: обратные вызовы шаблона карты (жесты, баннеры, выбор маршрута).
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        panSum = CGPoint(x: panSum.x + translation.x, y: panSum.y + translation.y)
        panUpdates += 1
        if panUpdates <= 3 {
            Log.carplay.notice("перетаскивание: шаг \(Int(translation.x), privacy: .public),\(Int(translation.y), privacy: .public), скорость \(Int(velocity.x), privacy: .public),\(Int(velocity.y), privacy: .public)")
        }
        model.pan(by: CGSize(width: translation.x, height: translation.y))
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        Log.carplay.notice("перетаскивание: конец, обновлений \(self.panUpdates, privacy: .public), сумма \(Int(self.panSum.x), privacy: .public),\(Int(self.panSum.y), privacy: .public)")
        panSum = .zero
    }

    /// Кнопки-стрелки на головных устройствах без сенсора: там панорамируют
    /// крутилкой, и шаг обязан быть заметным — иначе до соседнего квартала
    /// придётся щёлкать полминуты.
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     panWith direction: CPMapTemplate.PanDirection) {
        let step = AppConfig.carPlayPanStep
        var translation = CGSize.zero
        if direction.contains(.left)  { translation.width += step }
        if direction.contains(.right) { translation.width -= step }
        if direction.contains(.up)    { translation.height += step }
        if direction.contains(.down)  { translation.height -= step }
        model.pan(by: translation)
    }

    /// Стрелку держат: панорамируем, пока не отпустят. Один шаг на удержание
    /// заставлял щёлкать до соседнего квартала полминуты.
    ///
    /// Цикл обязан кончиться и без «отпустили»: событие конца теряется, если
    /// осмотр закрылся сам (автовозврат, камера впереди) или машину отключили —
    /// до 19.10 карта тогда ехала вечно, а `self?` без выхода держал шаблон
    /// (аудит CarPlay 19.10). Отсюда отмена в leavePanning/dismiss/disconnect
    /// и потолок шагов `CarPlayBrowse.panHoldContinues`.
    func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
        stopPanHold()
        panHoldTask = Task { @MainActor [weak self] in
            var steps = 0
            while !Task.isCancelled, CarPlayBrowse.panHoldContinues(steps: steps), let self {
                self.mapTemplate(mapTemplate, panWith: direction)
                steps += 1
                await Task.pause(seconds: AppConfig.carPlayPanHoldInterval)
            }
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
        stopPanHold()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint,
                     scale: CGFloat, velocity: CGFloat) {
        pinchUpdates += 1
        if pinchUpdates <= 3 {
            Log.carplay.notice("щипок: масштаб \(Double(scale), format: .fixed(precision: 3), privacy: .public), скорость \(Double(velocity), format: .fixed(precision: 2), privacy: .public)")
        }
        guard scale > 0, pinchLast > 0 else { return }
        model.pinch(scale: Double(scale / pinchLast))
        pinchLast = scale
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        Log.carplay.notice("щипок: конец, обновлений \(self.pinchUpdates, privacy: .public), итог \(Double(self.pinchLast), format: .fixed(precision: 3), privacy: .public)")
        pinchLast = 1
    }

    /// Система убрала баннер. Снят приложением (вытеснен камерой) — объезд и
    /// вопрос вернутся, когда экран освободится; закрыт водителем или истёк —
    /// нет. Вопрос, закрытый без ответа, — это «Пропустить»: ничего не шлём.
    func mapTemplate(_ mapTemplate: CPMapTemplate, didDismiss navigationAlert: CPNavigationAlert,
                     dismissalContext: CPNavigationAlert.DismissalContext) {
        if dismissalContext == .systemDismissed {
            forgetBanner(navigationAlert)
        } else if navigationAlert === confirmBanner {
            let id = confirmBannerID
            confirmBanner = nil
            confirmBannerID = nil
            // Истёк или закрыт: этот вопрос больше не задаём — иначе onIdle
            // ниже показал бы его снова, пока пропуск ждёт паузу.
            skippedConfirmID = id
            // Кнопка «Да»/«Нет» тоже закрывает баннер, и в каком порядке
            // придут её обработчик и это событие, CarPlay не обещает: пропуск
            // засчитываем с паузой, только если ответа так и не было.
            if let id {
                Task { @MainActor [weak self] in
                    await Task.pause(seconds: AppConfig.carPlayQuestionAnswerGraceSeconds)
                    guard let self, self.env.mobile.passQuestion?.id == id else { return }
                    self.env.mobile.answerPassQuestion(stillThere: nil, for: id)
                }
            }
        }
        banners?.didDismiss(navigationAlert, context: dismissalContext)
    }

    /// Ряд полос под манёвром — одной картинкой без текста (CarPlayGuidance.laneRow).
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     displayStyleFor maneuver: CPManeuver) -> CPManeuverDisplayStyle {
        CarPlayGuidance.isLaneRow(maneuver) ? .symbolOnly : []
    }

    // MARK: - Системные баннеры, когда на экране машины не мы

    /// Манёвр и камера доходят до водителя и поверх музыки или звонка:
    /// ради этого сессия и заведена.
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldShowNotificationFor maneuver: CPManeuver) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldUpdateNotificationFor maneuver: CPManeuver,
                     with travelEstimates: CPTravelEstimates) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldShowNotificationFor navigationAlert: CPNavigationAlert) -> Bool { true }

    /// Водитель отметил другой вариант: линия на карте — его, оценки — его.
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip,
                     using routeChoice: CPRouteChoice) {
        guard trip === previewTrip, let id = routeChoice.userInfo as? Int else { return }
        env.route.selectVariant(id)
        updatePreviewEstimates(env.route.selected)
        model.showOverview()
    }

    /// «Поехали».
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip,
                     using routeChoice: CPRouteChoice) {
        if let id = routeChoice.userInfo as? Int { env.route.selectVariant(id) }
        endPreview(start: true, keepRoute: true, reason: "Поехали")
    }
}

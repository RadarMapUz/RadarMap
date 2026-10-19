//
//  CarPlaySceneDelegate+Pan.swift
//  RadarMap
//
//  Панорамирование и масштаб в машине: жесты, панель панорамы и её выход.
//

import CarPlay
import SwiftUI
import os

extension CarPlaySceneDelegate {

    /// Перетаскивание пальцем. Само окно карты касаний не получает никогда
    /// (CPWindow: «does not receive tap or drag events») — жест приходит
    /// только сюда, и только от машин с сенсорным экраном: «CarPlay doesn't
    /// call this method when connected to some CarPlay systems». В CarPlay
    /// Simulator — только в профиле с `primaryInput: Touch`: в стандартных
    /// мышь идёт как тачпад (нажатия и фокус), и жеста нет вовсе.
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        panSum = .zero
        panUpdates = 0
        Log.carplay.notice("перетаскивание пальцем: начало")
    }

    func stopPanHold() {
        panHoldTask?.cancel()
        panHoldTask = nil
    }

    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        pinchLast = 1
        pinchUpdates = 0
        model.pinchBegan()
        Log.carplay.notice("щипок: начало")
    }

    /// Осмотр открылся — бар становится одной кнопкой «Готово». Своим
    /// вызовом `showPanningInterface` мы это и так знаем, но осмотр умеет
    /// открываться и мимо нас, и состояние кнопок обязано следовать за
    /// шаблоном, а не за нашим тапом.
    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        guard !isPanning else { return }
        isPanning = true
        syncTemplate()
        model.panningShown()
    }

    /// Осмотр закрыт — бар и кнопки карты отправляются ЗАНОВО, даже если по
    /// нашему ключу они «не менялись»: что показывает головное устройство
    /// после осмотра, решаем не мы, и кэш sentBar ему не указ.
    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        stopPanHold()
        isPanning = false
        panningFallback?.cancel()
        panningFallback = nil
        model.panningHidden()
        resendButtons()
    }

    /// Закрыть осмотр: шаблону — `dismissPanningInterface`, бар вернёт его
    /// событие (mapTemplateDidDismissPanningInterface). Событие приходит не
    /// всегда — осмотр мог так и не открыться (кнопку нажали в момент смены
    /// шаблона), — поэтому после паузы бар возвращаем сами: застрявшая
    /// «Готово» — ровно та пропажа кнопок, которую здесь чиним.
    func leavePanning(reason: String) {
        stopPanHold()
        guard isPanning, let mapTemplate else { return }
        Log.carplay.notice("осмотр закрываю: \(reason, privacy: .public)")
        mapTemplate.dismissPanningInterface(animated: true)
        panningFallback?.cancel()
        panningFallback = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayPanningDismissFallbackSeconds)
            guard !Task.isCancelled, let self, self.isPanning else { return }
            Log.carplay.fault("осмотр: закрытие не подтвердилось — бар возвращаю сам")
            self.isPanning = false
            self.model.panningHidden()
            self.resendButtons()
        }
    }

    /// Бар и кнопки карты — заново, мимо кэша «что уже отправлено».
    func resendButtons() {
        sentBar = nil
        sentMapButtons = nil
        syncTemplate()
    }
}

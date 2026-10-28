//
//  CarPlayOptionsPanel.swift
//  RadarMap
//
//  Панель «…» плашки прибытия в машине (25.H1, iOS 27):
//  `CPNavigationSession.optionsPanel`. Что в ней и когда её переписывать —
//  CarPlayOptionsPanelContent; здесь — сборка CPMapPanel и касания.
//
//  Панель живёт столько же, сколько навигационная сессия: каждая новая
//  сессия получает новую (`attach`), прежняя уходит вместе со своей.
//  Переписываются только секции (`sections` — readwrite), и только когда
//  это нужно водителю: открыта — не чаще раза в несколько секунд, закрыта —
//  при смене состава.
//

import CarPlay
import os

final class CarPlayOptionsPanel: NSObject {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// «Звук» — переключить (тишина ↔ прежний звук). Ставит делегат сцены.
    var onToggleSound: (() -> Void)?
    /// «Завершить маршрут»: снять маршрут, поездка и камеры остаются.
    var onEndRoute: (() -> Void)?

    /// CPMapPanel текущей сессии (тип — с iOS 27, поэтому без типа здесь).
    private var panel: AnyObject?
    private var shown: CarPlayOptionsPanelContent.Content?
    private var refreshedAt = Date.distantPast
    /// Панель открыта на экране машины (делегат CPMapPanel).
    private var visible = false
    /// Значки типов камер — один растр на тип за подключение.
    private var icons: [CameraType: UIImage] = [:]

    private var env: AppEnvironment { .shared }

    /// Новая панель для новой сессии.
    @available(iOS 27.0, *)
    func attach() -> CPMapPanel {
        let content = currentContent()
        let end = CPTextButton(title: String(localized: "Завершить маршрут"), textStyle: .cancel) { [weak self] _ in
            Log.carplay.notice("панель «…»: завершить маршрут")
            self?.onEndRoute?()
        }
        let buttons = CPMapPanelButtonConfiguration(primaryAction: end, secondaryButton: nil,
                                                    travelEstimates: estimates())
        let panel = CPMapPanel(title: nil, sections: sections(content), buttonConfiguration: buttons)
        panel.delegate = self
        self.panel = panel
        shown = content
        refreshedAt = Date()
        visible = false
        return panel
    }

    /// На каждом пересчёте ведения: переписать, если пора.
    func refresh(force: Bool = false) {
        guard #available(iOS 27.0, *), let panel = panel as? CPMapPanel else { return }
        let content = currentContent()
        let now = Date()
        guard force || CarPlayOptionsPanelContent.shouldRefresh(shown: shown, new: content,
                                                                 sinceLast: now.timeIntervalSince(refreshedAt),
                                                                 visible: visible) else { return }
        panel.sections = sections(content)
        panel.buttonConfiguration?.travelEstimates = estimates()
        shown = content
        refreshedAt = now
    }

    /// Подключение кончилось.
    func reset() {
        panel = nil
        shown = nil
        visible = false
        icons = [:]
    }

    // MARK: - Содержимое

    private func currentContent() -> CarPlayOptionsPanelContent.Content {
        let route = env.route
        let ahead = RouteCamerasAhead.list(route.camerasOnRoute, progress: route.progressAlong,
                                           limit: AppConfig.carPlayOptionsPanelCameras)
        let sound = CarPlaySoundChoice.current(soundEnabled: env.settings.soundEnabled,
                                               voiceMode: env.settings.voiceMode)
        return CarPlayOptionsPanelContent.content(ahead: ahead, sound: sound)
    }

    private func estimates() -> CPTravelEstimates {
        CarPlayGuidance.tripEstimates(meters: env.route.remainingDistance, seconds: env.route.arrivalSeconds())
    }

    @available(iOS 27.0, *)
    private func sections(_ content: CarPlayOptionsPanelContent.Content) -> [CPMapPanelSection] {
        let byID = Dictionary(env.route.camerasOnRoute.map { ($0.camera.id, $0.camera.kind) },
                              uniquingKeysWith: { first, _ in first })
        var cameraItems: [CPMapPanelItem] = content.cameras.map { row in
            let item = CPListItem(text: row.title, detailText: row.detail,
                                  image: byID[row.id].map(icon))
            return CPMapPanelItem(listItem: item)
        }
        if cameraItems.isEmpty {
            let none = CPMapPanelItem(listItem: CPListItem(text: String(localized: "Камер впереди по маршруту нет"),
                                                          detailText: nil))
            none.isEnabled = false
            cameraItems = [none]
        }
        let silent = content.sound == .silent
        let sound = CPListItem(text: silent ? String(localized: "Включить звук") : String(localized: "Выключить звук"),
                               detailText: String(format: String(localized: "Сейчас: %@"), content.sound.shortTitle),
                               image: UIImage(systemName: silent ? "speaker.wave.2.fill" : "speaker.slash.fill"))
        sound.handler = { [weak self] _, completion in
            Log.carplay.notice("панель «…»: звук")
            self?.onToggleSound?()
            completion()
        }
        return [CPMapPanelSection(title: String(localized: "Камеры впереди"), items: cameraItems),
                CPMapPanelSection(title: nil, items: [CPMapPanelItem(listItem: sound)])]
    }

    private func icon(_ type: CameraType) -> UIImage {
        if let cached = icons[type] { return cached }
        let image = CarPlayBannerArt.typeDisc(type, diameter: AppConfig.carPlayOptionsPanelIconPoints)
        icons[type] = image
        return image
    }
}

@available(iOS 27.0, *)
extension CarPlayOptionsPanel: CPMapPanel.Delegate {
    func panelDidShow(_ panel: CPMapPanel) {
        visible = true
        // Открыли по «…» — цифры свежие сразу, не через интервал.
        refresh(force: true)
    }

    func panelDidHide(_ panel: CPMapPanel) {
        visible = false
    }
}

//
//  CarPlayBanners.swift
//  RadarMap
//
//  Баннеры поверх карты машины (CPNavigationAlert) — одно место на все.
//
//  CarPlay показывает один баннер за раз, а новый при видимом прежнем молча
//  пропускает (CPMapTemplate.h). До 18.10 каждый показывал свой сам: объезд
//  пробки снимал баннер камеры, а подтверждения («Поездка началась», итог
//  поездки, ответ на «Радар!») и вопрос «радар ещё на месте?» шли модальными
//  окнами на весь экран — карта под ними пропадала (аудит 18.10, п. 4).
//  Руководство CarPlay для таких событий даёт именно баннер навигатора.
//
//  Здесь — очередь по важности: камера старше всего, подтверждение уступает
//  всему. Вытесненный вопрос или объезд не теряется: их владелец показывает
//  своё снова, когда экран освободится (`onIdle`).
//

import CarPlay
import os

/// Решение очереди. Чистая логика — покрыто CarPlayBannerPolicyTests.
nonisolated enum CarPlayBannerPolicy {

    /// Вид баннера — по возрастанию важности.
    enum Kind: Int, Comparable, Sendable, CustomStringConvertible {
        /// Подтверждение действия («Поездка началась»): опоздавшее не нужно.
        case info
        /// «Куда едем?» — предложение, которое можно и не показать.
        case suggestion
        /// «Радар ещё на месте?» — подождёт и вернётся.
        case question
        /// Объезд пробки — уступает только камере и запросу водителя.
        case detour
        /// Ответ на касание самого водителя («Завершить поездку?»): его не
        /// перебивают ни вопрос, ни объезд — пропавший вопрос читался бы как
        /// «нажатие не сработало». Не возвращается: устаревший не нужен.
        case request
        /// Камера впереди — всегда сверху.
        case camera

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// Не показанный или вытесненный баннер этого вида владелец покажет
        /// снова, когда экран освободится; остальные забываются.
        var comesBack: Bool { self == .question || self == .detour }

        var description: String {
            switch self {
            case .info:       return "подтверждение"
            case .suggestion: return "предложение"
            case .question:   return "вопрос"
            case .detour:     return "объезд"
            case .request:    return "запрос водителя"
            case .camera:     return "камера"
            }
        }
    }

    enum Decision: Equatable, Sendable {
        case present
        /// Снять показанный и показать новый.
        case replace
        /// Не сейчас — владелец покажет снова по `onIdle`.
        case wait
        /// Не показывать вовсе.
        case drop
    }

    static func decide(showing: Kind?, incoming: Kind) -> Decision {
        guard let showing else { return .present }
        // Тот же вид — новее: следующая камера, свежий итог, другой вопрос.
        if incoming >= showing { return .replace }
        return incoming.comesBack ? .wait : .drop
    }
}

/// Очередь баннеров одного подключения. Живёт, пока жив шаблон карты.
@MainActor
final class CarPlayBanners {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    typealias Kind = CarPlayBannerPolicy.Kind

    private weak var template: CPMapTemplate?
    /// Показанный нами баннер. Своя запись, а не `currentNavigationAlert`:
    /// то свойство может ходить в процесс хоста, а читается на пути тревоги
    /// (ARCHITECTURE.md, правило 21).
    private var current: (kind: Kind, alert: CPNavigationAlert)?
    /// Следующий, ждущий, пока система уберёт показанный.
    private var replacing: (kind: Kind, alert: CPNavigationAlert)?
    /// Экран освободился: владельцы ждущих (вопрос, объезд) показывают своё.
    var onIdle: (() -> Void)?
    /// Баннер, который мы считали показанным, так и не встал: его замену
    /// перебила более важная, пока прежний снимался. Владелец забывает, что
    /// показывал, — иначе объезд или вопрос не вернулись бы никогда.
    var onDropped: ((CPNavigationAlert) -> Void)?
    /// Последний баннер, который водитель закрыл сам («Понятно», крестик): о
    /// той же камере больше не напоминаем.
    private weak var closedByDriver: CPNavigationAlert?

    init(template: CPMapTemplate) {
        self.template = template
    }

    /// Что сейчас на экране (или вот-вот встанет).
    var showingKind: Kind? { replacing?.kind ?? current?.kind }

    func isShowing(_ alert: CPNavigationAlert) -> Bool {
        current?.alert === alert || replacing?.alert === alert
    }

    /// Показать, если очередь позволяет; false — ждёт или выброшен.
    @discardableResult
    func show(_ alert: CPNavigationAlert, kind: Kind) -> Bool {
        guard let template else { return false }
        switch CarPlayBannerPolicy.decide(showing: showingKind, incoming: kind) {
        case .present:
            current = (kind, alert)
            template.present(navigationAlert: alert, animated: true)
            return true
        case .replace:
            // Новый при видимом прежнем CarPlay молча не покажет: сначала
            // снять, показать — из completion (через didDismiss onIdle не
            // зовётся, пока замена ждёт). Ждущую замену перебивает более
            // важная — та, ждавшая, не встанет: сказать владельцу.
            let waiting = replacing
            replacing = (kind, alert)
            if let waiting {
                onDropped?(waiting.alert)
                return true
            }
            template.dismissNavigationAlert(animated: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.presentReplacement() }
            }
            return true
        case .wait, .drop:
            Log.carplay.notice("баннер «\(kind.description, privacy: .public)» не показан: на экране «\(self.showingKind?.description ?? "", privacy: .public)»")
            return false
        }
    }

    /// Снять свой баннер: камеру проехали, на вопрос ответили на телефоне.
    /// Нового на его место владелец так не ставит — замену делает `show`.
    func dismiss(_ alert: CPNavigationAlert) {
        if replacing?.alert === alert {
            replacing = nil
            return
        }
        guard current?.alert === alert, let template else { return }
        template.dismissNavigationAlert(animated: true) { [weak self] dismissed in
            guard !dismissed else { return }   // событие didDismiss придёт от системы
            Task { @MainActor [weak self] in
                // Снимать было нечего: баннер уже ушёл, а события о нём не
                // было — иначе очередь считала бы экран занятым навсегда.
                guard let self, self.current?.alert === alert else { return }
                self.current = nil
                if self.replacing == nil { self.onIdle?() }
            }
        }
    }

    /// Система убрала баннер: истёк, нажата кнопка или снят нами.
    func didDismiss(_ alert: CPNavigationAlert, context: CPNavigationAlert.DismissalContext) {
        if context == .userDismissed { closedByDriver = alert }
        guard current?.alert === alert else { return }
        current = nil
        guard replacing == nil else { return }   // следующий покажет presentReplacement
        onIdle?()
    }

    /// Водитель закрыл этот баннер сам.
    func wasClosedByDriver(_ alert: CPNavigationAlert) -> Bool {
        closedByDriver === alert
    }

    /// Подключение кончилось — шаблона больше нет.
    func reset() {
        current = nil
        replacing = nil
        onIdle = nil
        onDropped = nil
    }

    private func presentReplacement() {
        guard let next = replacing, let template else {
            if current == nil { onIdle?() }
            return
        }
        replacing = nil
        current = next
        template.present(navigationAlert: next.alert, animated: true)
    }
}

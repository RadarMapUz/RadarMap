//
//  StartTripPrompt.swift
//  RadarMap
//
//  Вопрос «Начать поездку?» на radarmap://start-trip без ключа своих кнопок
//  (TripLink). UIKit, а не `.alert` на RootView: ссылка приходит, когда
//  открыт любой шит карты (Настройки, Итоги, поиск), а алерт корня поверх
//  чужого шита SwiftUI не показывает — нажатие молча пропадало бы. Здесь
//  вопрос встаёт на самый верхний показанный экран.
//

import UIKit

enum StartTripPrompt {

    /// Показать вопрос; false — показать не на чем (окна телефона нет).
    @discardableResult
    static func present(start: @escaping () -> Void) -> Bool {
        guard let top = topController() else { return false }
        let alert = UIAlertController(title: String(localized: "Начать поездку?"),
                                      message: String(localized: "GPS будет работать постоянно, пока поездка не закончится."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Начать"), style: .default) { _ in start() })
        top.present(alert, animated: true)
        return true
    }

    /// Вопрос на ссылку маршрута без ключа своих кнопок (TripLink.GoDecision).
    @discardableResult
    static func presentRoute(title: String, build: @escaping () -> Void) -> Bool {
        guard let top = topController() else { return false }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Построить"), style: .default) { _ in build() })
        top.present(alert, animated: true)
        return true
    }

    /// Верхний показанный контроллер окна телефона (не CarPlay).
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let window = scenes.lazy.compactMap { $0.keyWindow }.first
            ?? scenes.lazy.flatMap(\.windows).first
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        // Уже висит другой вопрос — второй UIKit не покажет; не мешаем ему.
        return top is UIAlertController ? nil : top
    }
}

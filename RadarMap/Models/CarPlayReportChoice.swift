//
//  CarPlayReportChoice.swift
//  RadarMap
//
//  Выбор типа отметки в машине — баннером навигатора поверх карты
//  (вариант B, 02.11; спецификация CarPlay A4–A5).
//
//  iOS 27: все три типа кнопками в самом баннере — «Тренога» (выделена
//  цветом), «Пост ДПС», «ДТП» — и системный крестик (= «✕», не уходит
//  ничего). Число кнопок система сообщает только во время работы
//  (`maximumActionsCount`); не влезают все три — путь до iOS 27.
//
//  До iOS 27 у баннера две кнопки и крестика нет: «Пост · ДТП…» (сетка) и
//  «Отмена». Тренога — молчанием или вторым касанием «Отметить»: отдельной
//  кнопки ей не досталось, потому что обе отданы отмене (главное правило B:
//  ошибочное касание ничего не отправляет) и пути к посту и ДТП.
//
//  Чистая логика; CarPlayReportChoiceTests.
//

import CoreGraphics

nonisolated enum CarPlayReportChoice {

    enum Layout: Equatable {
        /// Типы — кнопками баннера (iOS 27, места хватает).
        case inBanner([ReportKind])
        /// «Пост · ДТП…» → сетка, «Отмена» (до iOS 27 или кнопок мало).
        case viaGrid
    }

    /// `maximumActions` — `CPNavigationAlert.maximumActionsCount`; nil — до
    /// iOS 27 (массива кнопок нет).
    static func layout(maximumActions: Int?) -> Layout {
        let kinds = ReportKind.chosenOnTheGo
        guard let maximumActions, maximumActions >= kinds.count else { return .viaGrid }
        return .inBanner(kinds)
    }

    /// Показывать ли баннер «отмечена · Отменить» после того, как экран
    /// освободился: система держит баннер не меньше 5 с, и «Отменить», которое
    /// исчезнет раньше, чем его прочтут, не нужно.
    static func showsUndoBanner(remaining: Double,
                                minimum: Double = AppConfig.reportUndoBannerMinSeconds) -> Bool {
        remaining >= minimum
    }

    /// Самый мелкий кегль слова на диске кнопки карты, который читается за
    /// взгляд. «Отметить» и «Belgilash» в диске 40 pt выходят около 6 pt —
    /// тогда диск остаётся со значком без слова.
    static let minDiscTitlePoints: CGFloat = 9

    static func discShowsTitle(fittedPoints: CGFloat) -> Bool {
        fittedPoints >= minDiscTitlePoints
    }
}

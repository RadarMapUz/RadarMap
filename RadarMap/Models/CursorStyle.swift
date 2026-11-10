//
//  CursorStyle.swift
//  RadarMap
//
//  Каким значком на карте нарисована «я» — машина водителя.
//
//  Выбор значка — не украшательство ради украшательства. Курсор — самый
//  важный предмет на экране: на него смотрят чаще, чем на любую камеру, и
//  навигаторы, которыми пользуются годами (Яндекс, Waze), дают выбрать его
//  именно поэтому — «своя» машина на карте находится взглядом быстрее чужой
//  стрелки. Поведение от выбора не меняется ни на градус: значок вращается по
//  тому же курсу, стоит в той же точке, а без курса так же уступает место
//  точке «курс неизвестен».
//
//  Все значки — сверху, носом ВВЕРХ (на север): поворот по курсу работает без
//  поправок. Стрелка рисуется в SwiftUI (MeCursor), машины — готовые картинки
//  из каталога (Cursors/cursor-<id>), отрендеренные офлайн из 3D-моделей
//  скриптом tools/cursors. Имена — типы машин, не марки.
//
//  Чистое правило хранения и миграции — покрыто CursorStyleTests.
//

import Foundation

nonisolated enum CursorStyle: String, CaseIterable, Identifiable, Sendable {
    /// Стрелка-конус — облик курсора до появления выбора. По умолчанию.
    case arrow
    /// Чёрный представительский седан с люком.
    case premium
    /// Большой премиальный внедорожник: панорамная крыша, рейлинги.
    case suv
    case crossover
    /// Жёлтое такси с шашками на крыше.
    case taxi
    case sport
    /// Гранёный пикап из нержавейки.
    case pickup
    case moto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow:     return String(localized: "Стрелка")
        case .premium:   return String(localized: "Премиум седан")
        case .suv:       return String(localized: "Внедорожник")
        case .crossover: return String(localized: "Кроссовер")
        case .taxi:      return String(localized: "Такси")
        case .sport:     return String(localized: "Спорткар")
        case .pickup:    return String(localized: "Пикап-клин")
        case .moto:      return String(localized: "Мотоцикл")
        }
    }

    /// Картинка машины в каталоге; у стрелки её нет — она рисуется.
    var assetName: String? { self == .arrow ? nil : "cursor-\(rawValue)" }

    /// Рамка значка без полей, точки. Картинка машины — 44×60 pt: эта рамка
    /// плюс поля по 8 pt под тень и ободок, как у стрелки.
    var frameSize: CGSize {
        self == .arrow ? CGSize(width: 30, height: 36) : CGSize(width: 28, height: 44)
    }

    /// Поля вокруг рамки под тень, точки — у всех значков одни.
    static let padding: CGFloat = 8

    /// Значки до 3D-машин (10.11) → ближайший новый: выбор водителя не
    /// сбрасывается в стрелку только потому, что старый рисунок убран.
    static let legacy: [String: CursorStyle] = [
        "car": .crossover, "car3D": .crossover,
        "formula": .sport, "supercar": .sport, "rally": .sport,
        "spaceship": .arrow,
    ]

    /// Значение из хранилища. Неизвестное (значок из будущей версии, ручная
    /// правка, мусор) — стрелка: курсор обязан нарисоваться всегда.
    init(stored raw: String?) {
        guard let raw else { self = .arrow; return }
        self = CursorStyle(rawValue: raw) ?? Self.legacy[raw] ?? .arrow
    }
}

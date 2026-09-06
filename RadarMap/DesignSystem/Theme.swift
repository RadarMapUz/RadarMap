//
//  Theme.swift
//  RadarMap
//
//  Палитра и метрики тёмного интерфейса «радар-детектора».
//
//  ГЛАВНОЕ ПРАВИЛО: цветом кодируется СОСТОЯНИЕ (норма → внимание → опасность),
//  а тип объекта различается глифом и формой. До этого цвет значил и то и
//  другое сразу: `camera` был побайтово равен `danger` (красный означал и «тип
//  камеры», и «ты нарушаешь»), `radar` — и тип, и «внимание», плюс мимо темы
//  жили .orange, .yellow и захардкоженные Color(red:) — до десяти оттенков на
//  экране. Когда цвет значит всё, он не значит ничего: в момент тревоги
//  водитель не должен разбирать, этот красный про штраф или про модель камеры.
//
//  Отсюда три слоя:
//   • состояния  — accent / warning / danger / success, выдаются через role(_:);
//   • типы камер — приглушённое семейство `Types`, оно не спорит с состояниями;
//   • поверхности и текст — фон, карточка, обводка, три уровня контраста.
//

import SwiftUI

enum Theme {

    // MARK: - Состояния (единственные «громкие» цвета интерфейса)

    /// Нейтральное действие и всё «своё»: маршрут, кнопки, ссылки, акценты.
    static let accent  = Color(red: 0.235, green: 0.863, blue: 1.0)   // неоновый циан
    /// Внимание: приближение к камере, превышение в допуске, «на грани».
    static let warning = Color(red: 1.0,   green: 0.71,  blue: 0.15)  // янтарный
    /// Опасность: штрафуемое превышение, камера вплотную, ошибка.
    static let danger  = Color(red: 1.0,   green: 0.27,  blue: 0.38)  // красный
    /// Норма: в лимите, чисто, выполнено.
    static let success = Color(red: 0.22,  green: 0.9,   blue: 0.55)  // зелёный

    /// Состояние объекта — единственный законный способ выбрать «смысловой»
    /// цвет там, где состояние вычисляется. Прямая ссылка на warning/danger
    /// остаётся законной для статичной разметки (иконка раздела и т.п.).
    enum Level {
        case normal     // всё в порядке
        case attention  // стоит посмотреть
        case alarm      // требует действия
        case neutral    // без оценки
    }

    static func role(_ level: Level) -> Color {
        switch level {
        case .normal:    return success
        case .attention: return warning
        case .alarm:     return danger
        case .neutral:   return accent
        }
    }

    /// Состояние по скорости относительно лимита — общее правило всего
    /// приложения: HUD телефона, панель CarPlay, строки проездов и Итоги
    /// обязаны красить одну и ту же ситуацию одинаково.
    /// `tolerance` — допуск, ниже которого превышение не считаем даже вниманием.
    static func speedLevel(speedKmh: Double, limitKmh: Int?, tolerance: Double = 2) -> Level {
        guard let limitKmh else { return .neutral }
        let over = speedKmh - Double(limitKmh)
        if over <= tolerance { return .normal }
        // Штрафной ступени ещё нет — это «внимание», а не «опасность».
        return FineSchedule.fine(overKmh: over) == 0 ? .attention : .alarm
    }

    /// Цвет балла поездки и рейтинга периода — ЕДИНСТВЕННЫЙ источник шкалы:
    /// кольцо на экране, строка истории, бейдж на карточке для шеринга.
    ///
    /// Появился из настоящего расхождения: карточка, которой делятся с
    /// друзьями, красила 55 жёлтым (`score >= 55`), а само приложение —
    /// красным (`DrivingScore.tier`). Человек показывал наружу оценку лучше
    /// той, что видел сам. Пороги живут в модели (tier), цвет — здесь, и
    /// второго места, где это решается, быть не должно.
    static func score(_ value: Int) -> Color {
        switch DrivingScore.tier(for: value) {
        case 2:  return success
        case 1:  return warning
        default: return danger
        }
    }

    // MARK: - Типы камер
    //
    // Приглушённое семейство: тип узнаётся по глифу, цвет здесь — лишь
    // подсказка «это другой вид точки». Насыщенность заметно ниже, чем у
    // состояний, поэтому маркер камеры больше не читается как тревога.

    enum Types {
        /// Стационарная камера.
        static let camera      = Color(red: 0.94, green: 0.45, blue: 0.55)
        /// Стационарный радар и тренога.
        static let radar       = Color(red: 0.95, green: 0.74, blue: 0.40)
        /// Интеллектуальная камера + радар.
        static let intelligent = Color(red: 0.45, green: 0.60, blue: 1.0)
        /// Передвижной радар (краудсорс).
        static let mobile      = Color(red: 0.72, green: 0.45, blue: 1.0)
        /// Пост ДПС.
        static let post        = Color(red: 0.36, green: 0.78, blue: 0.86)
        /// ДТП — единственный тип с «громким» цветом: это не характеристика
        /// точки, а событие, которое требует внимания прямо сейчас.
        static let accident    = Theme.danger
    }

    // MARK: - Поверхности и текст

    static let background    = Color(red: 0.02,  green: 0.04,  blue: 0.07)  // почти чёрный навигационный
    static let surface       = Color(red: 0.07,  green: 0.09,  blue: 0.14)
    static let stroke        = Color.white.opacity(0.10)

    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    /// 0.50, а не 0.38: на почти чёрном фоне приложения прежняя ступень давала
    /// контраст 3.5:1 при пороге WCAG AA 4.5:1 — и это не абстракция, а 117
    /// подписей под цифрами, которые читают на ходу, в машине, через блик.
    /// 0.50 даёт 5.3:1 и всё ещё отличается от textSecondary на глаз.
    static let textTertiary  = Color.white.opacity(0.50)

    // MARK: - Метрики

    /// Радиус ПАНЕЛИ поверх карты — один на все.
    ///
    /// Их было три: карточка скорости 22, панель поездки 26, приборка 24.
    /// Разница в четыре пункта не читается как замысел, читается как небрежность:
    /// на одном экране рядом стоят три почти одинаковых, но разных угла.
    /// Панель поверх карты — один предмет с одним углом; круглая кнопка —
    /// второй. Больше форм на этом экране нет.
    // MARK: - Кромка и подъём
    //
    // Стеклянная поверхность ловит свет сверху и отбрасывает тень вниз. Три
    // варианта кромки — не разнобой, а разные роли: панель лежит на карте,
    // круглая кнопка выступает над ней, CTA светится ярче всего.
    //
    // До этого все шесть кромок и семь теней были скопированы литералами по
    // файлам. Значения не тронуты ни на сотую — названы ровно те, что были:
    // задача токена не поменять вид, а сделать невозможным седьмой вариант,
    // появившийся «потому что рядом было похожее».

    /// Кромка панели: карточка, бар действий, панель слоёв.
    static let edgePanel = LinearGradient(
        colors: [.white.opacity(0.16), .white.opacity(0.02)],
        startPoint: .top, endPoint: .bottom)

    /// Кромка круглой кнопки поверх карты.
    static let edgeControl = LinearGradient(
        colors: [.white.opacity(0.22), .white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom)

    /// Кромка акцентной кнопки: света больше, потому что она главная.
    static let edgeAccent = LinearGradient(
        colors: [.white.opacity(0.45), .white.opacity(0.03)],
        startPoint: .top, endPoint: .bottom)

    static let cornerPanel: CGFloat  = 24
    static let cornerLarge: CGFloat  = 24
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat  = 12

    /// Скругление кнопки действия. Число из системы выпадало (12 и 16 рядом,
    /// а тут 14) и стояло сырым в двух местах — «Радар!» и «Стоп». Оно названо,
    /// а не подтянуто к соседям: подтягивать значит двигать вёрстку, и это
    /// решение принимается с телефоном в руках, а не компилятором.
    static let cornerControl: CGFloat = 14
}

// MARK: - Типографика (rounded — «приборный» вид)

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Цвет/иконка для типа камеры (UI-слой, модель остаётся без SwiftUI)

extension CameraType {
    var tint: Color {
        switch self {
        case .stationaryCamera: return Theme.Types.camera
        case .stationaryRadar:  return Theme.Types.radar
        case .intelligentRadar: return Theme.Types.intelligent
        case .mobileRadar:      return Theme.Types.mobile
        case .tripod:           return Theme.Types.radar
        case .dpsPost:          return Theme.Types.post
        case .accident:         return Theme.Types.accident
        case .other:            return Theme.textSecondary
        }
    }
}

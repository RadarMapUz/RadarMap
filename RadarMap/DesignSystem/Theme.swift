//
//  Theme.swift
//  RadarMap
//
//  Палитра и метрики интерфейса: светлые панели днём, графит ночью.
//
//  ПЕРЕСМОТР 7 октября: тёмный неоновый «радар-детектор» (циан на почти
//  чёрном синем) владелец назвал неприятным. Новая палитра — в духе
//  Яндекс Навигатора: белые панели днём, графитовые ночью, один жёлтый
//  акцент только на главном действии. Каждый токен проверен расчётом:
//  текстовые — не ниже 4,5:1 и на фоне, и на карточке, в обеих темах;
//  маркеры типов — различимы при дейтеранопии/протанопии/тританопии.
//  Макет: https://claude.ai/artifact/KVGkR4VWkSTneGn4SZHhbs.
//
//  ПЕРЕСМОТР 10 октября — вариант А «Синий навигатор» из трёх на том же
//  макете (второй ряд): холодные светлые панели, нейтральный графит ночью
//  без синевы (тёмно-синий неон отвергнут 7-го), синяя карточка манёвра с
//  белым текстом и один синий маршрут на всех картах. Жёлтый — по-прежнему
//  только главное действие, один на экран.
//
//  Токены АДАПТИВНЫЕ: один и тот же `Theme.textPrimary` чёрный днём и
//  светлый ночью, решает схема окружения (AppEnvironment.interfaceScheme;
//  приборка и экран тревоги всегда тёмные — они задают схему себе сами).
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
#if canImport(UIKit)
import UIKit
#endif

enum Theme {

    /// Цвет по теме: `light` днём, `dark` ночью. Решает схема окружения
    /// SwiftUI, а не системная настройка iOS.
    /// nonisolated: чистая сборка цвета, её зовут и nonisolated-палитры
    /// карты (MapPalette) при ленивой инициализации своих констант.
    nonisolated static func adaptive(_ light: UInt32, _ dark: UInt32,
                         lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: adaptiveUIColor(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    /// То же для UIKit: динамический UIColor с вариантами светлой и тёмной
    /// темы. CarPlay (карточка манёвра, CPRouteDetail) принимает только
    /// динамический цвет — статичный он молча заменяет системным.
    nonisolated static func adaptiveUIColor(_ light: UInt32, _ dark: UInt32,
                                            lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }

    nonisolated static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // MARK: - Состояния (единственные «громкие» цвета интерфейса)

    /// Выделение и всё «своё»: маршрут, выбранное, ссылки, значки активного.
    /// Синий, а не жёлтый: этот цвет бывает ТЕКСТОМ, а жёлтый текст на белой
    /// панели не читается (1,3:1). 4,9:1 днём, 5,3:1 ночью.
    static let accent  = adaptive(0x2563D9, 0x6BA3FF)
    /// Главное действие — заливка кнопки («Радар!», «Поехали»). Один на экран.
    /// Текст на нём — `onAction` (11,9:1).
    static let action  = Color(uiColor: rgb(0xFFD43B))
    static let onAction = Color(uiColor: rgb(0x1C1C1E))
    /// Внимание: приближение к камере, превышение в допуске, «на грани».
    static let warning = adaptive(0x9A5800, 0xFFB020)
    /// Опасность: штрафуемое превышение, камера вплотную, ошибка.
    /// nonisolated — читается кольцом камеры в MapPalette (nonisolated).
    nonisolated static let danger  = adaptive(0xC62828, 0xFF7A70)
    /// Норма: в лимите, чисто, выполнено.
    static let success = adaptive(0x177A41, 0x4CC27A)

    // MARK: - Маршрут и манёвр
    //
    // Вариант А «Синий навигатор» (10 октября, выбран владельцем из трёх на
    // макете): маршрут, карточка манёвра и всё «куда я еду» — один синий.
    // До этого у маршрута было ТРИ цвета на трёх картах: зелёный на движке
    // (остаток неоновой темы 8 сентября), зелёный `success` на схеме и
    // градиент синий→индиго на карте Apple. Зелёный маршрут к тому же спорил
    // с `success` — «в лимите» и «твой путь» красились одним цветом.

    /// Заливка под БЕЛЫМ текстом: карточка манёвра, синяя кнопка. Ночью
    /// `accent` светлый (он бывает текстом на графите), и белое на нём не
    /// читается (2,4:1) — поэтому заливка отдельным токеном: 5,4:1 / 5,5:1.
    static let accentFill = Color(uiColor: accentFillUIColor)
    /// `accentFill` для UIKit.
    nonisolated static let accentFillUIColor = adaptiveUIColor(0x2563D9, 0x2A62D6)
    /// Карточка манёвра CarPlay (CPManeuver.cardBackgroundColor) — синий
    /// ТЕМНЕЕ `accentFill`. CarPlay принимает фон карточки только при
    /// контрасте с белым не ниже 7:1 (замер 21.10: сеттер CPManeuver отдаёт
    /// назад системный белый/чёрный для 6,96:1 и принимает 7,07:1), а у
    /// `accentFill` 5,4:1 — отсюда чёрная карточка в машине. 7,2:1; по
    /// оттенку — как у карточки Яндекса (снимок 65). Один цвет на обе темы:
    /// сеттер CarPlay динамический цвет не хранит, а замораживает в одном
    /// варианте (замер: светлый вариант читался назад тёмным) — второй
    /// вариант всё равно не доехал бы до машины.
    nonisolated static let carPlayCardFillUIColor = adaptiveUIColor(0x124EC4, 0x124EC4)
    static let onAccentFill = Color(uiColor: rgb(0xFFFFFF))
    /// Вторая строка на синей заливке (улица под расстоянием) — 4,8:1 / 5,0:1.
    static let onAccentFillSecondary = adaptive(0xEAF0FD, 0xEEF3FD)

    /// Заливки состояний под БЕЛЫМ текстом — по той же причине, что
    /// `accentFill`: ночные `danger`/`success` светлые (они бывают текстом на
    /// графите), и белое на них читалось 2,2–2,6:1 — «Стоп», «Завершить
    /// поездку», «Да»/«Нет» на приборке. Белый на заливке ≥ 4,9:1 в обеих темах.
    static let dangerFill = adaptive(0xC62828, 0xD0362C)
    static let successFill = adaptive(0x177A41, 0x1A7F45)

    /// Линия маршрута — одна на движке (телефон и машина) и на картинках
    /// «Итогов». Числа — в `RouteColors`: стиль движка — JSON и берёт их
    /// строкой оттуда же, второго списка цветов нет.
    /// Ночью с 21.10 чуть светлее (#5B9BFF → #66A3FF): на графите магистрали
    /// линия держала 2,8:1 — ниже 3:1, которые нужны линии на дороге.
    nonisolated static let route = adaptive(RouteColors.body.day, RouteColors.body.night)
    /// Кайма линии: тёмно-синяя днём (с 21.10; белая сливалась со светло-
    /// серым полотном — 1,4–2,1:1) и тёмно-синяя ночью.
    static let routeCasing = adaptive(RouteColors.casing.day, RouteColors.casing.night)
    /// Пройденная часть маршрута — бледнее: она уже не решение, а память.
    static let routeTraveled = adaptive(RouteColors.traveled.day, RouteColors.traveled.night)
    /// Светлая середина линии — белым поверх тела (и поверх цвета пробки).
    static let routeCore = adaptive(0xFFFFFF, 0xFFFFFF,
                                    lightAlpha: RouteColors.coreAlpha.day,
                                    darkAlpha: RouteColors.coreAlpha.night)
    /// Пробка и «медленно» на линии маршрута (те же, что слой пробок).
    static let routeSlow = adaptive(RouteColors.slow.day, RouteColors.slow.night)
    static let routeJam = adaptive(RouteColors.jam.day, RouteColors.jam.night)
    /// Другой вариант маршрута при выборе — бледнее выбранного (27.D): его
    /// цвет и на карте, и полоской у карточки варианта.
    static let routeAlternative = adaptive(RouteColors.alternative.day, RouteColors.alternative.night)
    static let routeAlternativeCasing = adaptive(RouteColors.alternativeCasing.day,
                                                 RouteColors.alternativeCasing.night)

    /// Цвета знаков-иконок (`IconBadge`) — по СМЫСЛУ цифры рядом. Глаз ищет
    /// «время» и «деньги» по цвету раньше, чем прочтёт подпись, поэтому смысл
    /// красится одинаково на всех экранах. Глиф на своей плашке и на карточке
    /// держит ≥ 3:1 в обеих темах (PaletteTests).
    enum Icon {
        static let time     = Theme.accent
        static let distance = adaptive(0x0B7480, 0x45C6CF)
        static let speed    = adaptive(0x6A3FD1, 0xAE93FF)
        static let money    = Theme.warning
        static let rating   = Theme.success
        static let camera   = Theme.danger
        static let home     = Theme.accent
        static let work     = adaptive(0x9C5300, 0xF2A54A)
        static let streak   = adaptive(0xC2410C, 0xFF8A4C)
    }

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

    /// ВТОРОЙ носитель состояния — глиф рядом с цветом.
    ///
    /// Зачем он нужен, считается, а не предполагается. ΔE между `danger` и
    /// `success` при нормальном зрении 135, при дейтеранопии — **17,9**:
    /// красный и зелёный сливаются. Дейтеранопия есть примерно у 6 %
    /// мужчин, то есть у каждого шестнадцатого водителя.
    ///
    /// Само по себе это ещё не беда — беда в том, что цвет был ЕДИНСТВЕННЫМ
    /// носителем ровно там, где решается главный вопрос приложения «превышаю
    /// я сейчас или нет»: цифра скорости во весь экран, та же цифра на панели
    /// машины, строки проездов, точки на карте и на графике. Ни глифа, ни
    /// формы, ни подписи — «58» и «68» выглядели одинаково.
    ///
    /// Развести саму палитру нельзя: уводя `success` к бирюзе, мы сажаем его
    /// на `accent` (там уже ΔE 68,8, и он упадёт), то есть меняем одну
    /// неразличимую пару на другую. Поэтому добавлен второй канал.
    ///
    /// **Норма и «нет оценки» глифа не получают, и это не экономия.**
    /// Отсутствие значка — такой же однозначный сигнал, как его наличие, а
    /// вечная зелёная галочка у скорости превращается в фон, который
    /// перестают замечать к третьей поездке. Различает состояния ФОРМА
    /// значка: круг — «на грани», треугольник — «штраф».
    static func symbol(_ level: Level) -> String? {
        switch level {
        case .attention:        return "exclamationmark.circle.fill"
        case .alarm:            return "exclamationmark.triangle.fill"
        case .normal, .neutral: return nil
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
    // Маркер — цветной круг с белым кольцом (читается на любой подложке),
    // тип различает и цвет, и глиф. Подбор расчётом: камера и радар
    // различаются СВЕТЛОТОЙ (красный с белым значком / светлый янтарь с
    // тёмным), поэтому не сливаются и при дейтеранопии; значок на каждом
    // круге — не ниже 4,6:1. Цвет типа — не цвет состояния: тревогу несёт
    // ореол и размер маркера, а не его заливка.

    enum Types {
        /// Стационарная камера.
        static let camera      = Color(uiColor: rgb(0xD93025))
        /// Стационарный радар и тренога — СВЕТЛЫЙ: глиф на нём тёмный (glyph(on:)).
        static let radar       = Color(uiColor: rgb(0xF2B200))
        /// Интеллектуальная камера + радар. Индиго, а не синий: синим говорит
        /// интерфейс (accent), и маркер читался бы кнопкой (ΔE 12 → 30).
        static let intelligent = Color(uiColor: rgb(0x6A3FD6))
        /// Передвижной радар (краудсорс). Неподтверждённая — пунктир кольца.
        static let mobile      = Color(uiColor: rgb(0xC2409E))
        /// Пост ДПС.
        static let post        = Color(uiColor: rgb(0x46525E))
        /// ДТП — событие, а не характеристика точки: цвет опасности.
        static let accident    = Theme.danger
        /// Кольцо маркера.
        static let ring        = Color.white
        /// Глиф на СВЕТЛОЙ заливке (радар, тренога) — 9:1.
        static let darkGlyph   = Color(uiColor: rgb(0x1C1C1E))
    }

    // MARK: - Поверхности и текст

    static let background    = adaptive(0xF1F4F9, 0x111418)
    static let surface       = adaptive(0xFFFFFF, 0x1E232A)
    static let stroke        = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// Подложка экрана тревоги — всегда графит, днём тоже: на белом фоне
    /// цифра расстояния читалась бы, но полоса цвета типа — нет (13.10).
    static let alertSurface  = Color(uiColor: rgb(0x14181D))

    // MARK: - Глубина
    //
    // Облик выбран 25 сентября из трёх показанных вариантов. Жалоба была
    // «плоско и серо», и плоско здесь было буквально: карточки лежали ровной
    // заливкой на ровном фоне, все на одной высоте, и экран не расставлял
    // ничего по важности.
    //
    // Языка при этом не хватало ровно наполовину: кромка (`edgePanel`) и тень
    // (`liftPanel`) в проекте уже были — ими крашены панели ПОВЕРХ КАРТЫ. До
    // карточек контента они просто не доехали. Ниже — недостающая половина,
    // и дальше «глубина» это не новый стиль, а тот же, доведённый до конца.

    /// Верх карточки: поверхность, поймавшая свет. Пара к `surface` — низ.
    static let surfaceTop = adaptive(0xFFFFFF, 0x252B33)

    /// Заливка карточки: светлее сверху, темнее снизу. Один градиент даёт
    /// больше объёма, чем любая тень на почти чёрном фоне, — тень там просто
    /// не видна, а перепад светлоты виден.
    static let surfaceRaised = LinearGradient(colors: [surfaceTop, surface],
                                              startPoint: .top, endPoint: .bottom)

    /// Тень карточки контента. Днём — едва заметная холодная (0,07): прежние
    /// 0,35 чёрного подбирались под тёмную тему и на белом фоне лежали серыми
    /// пятнами вокруг каждой карточки. Ночью тень почти не видна и нужна
    /// только как отрыв от фона — там объём даёт градиент заливки.
    static let cardShadow = adaptive(0x0B1B33, 0x000000, lightAlpha: 0.07, darkAlpha: 0.35)
    /// Тень панели над картой: днём заметнее карточки (карта пёстрая), но не
    /// 0,3 тёмной темы.
    static let panelShadow = adaptive(0x0B1B33, 0x000000, lightAlpha: 0.16, darkAlpha: 0.30)

    /// Фон экрана: свет сверху, темнота к низу. Плоский `background` остаётся
    /// для мест, где нужна именно КРАСКА (точка на карте, подложка значка), —
    /// градиент туда класть незачем.
    static let screenBackground = RadialGradient(
        colors: [adaptive(0xFAFBFD, 0x1A1F26), background],
        center: .top, startRadius: 0, endRadius: 620)

    static let textPrimary   = adaptive(0x111827, 0xF1F4F8)
    static let textSecondary = adaptive(0x556070, 0xA0A9B6)
    /// 0.50, а не 0.38: на почти чёрном фоне приложения прежняя ступень давала
    /// контраст 3.5:1 при пороге WCAG AA 4.5:1 — и это не абстракция, а 117
    /// подписей под цифрами, которые читают на ходу, в машине, через блик.
    /// 0.50 даёт 5.3:1 и всё ещё отличается от textSecondary на глаз.
    /// Пересчитано 7 октября: 4,7:1 и днём, и ночью, на фоне и на карточке.
    static let textTertiary  = adaptive(0x657080, 0x8F99A6)

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
        colors: [adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.16),
                 adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.02)],
        startPoint: .top, endPoint: .bottom)

    /// Кромка круглой кнопки поверх карты.
    static let edgeControl = LinearGradient(
        colors: [adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.22),
                 adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.04)],
        startPoint: .top, endPoint: .bottom)

    /// Кромка акцентной кнопки: света больше, потому что она главная.
    static let edgeAccent = LinearGradient(
        colors: [adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.45),
                 adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.03)],
        startPoint: .top, endPoint: .bottom)

    // MARK: - Сетка отступов
    //
    // Шаг — ДВА пункта, и это не введено сейчас, а обнаружено: из двадцати двух
    // значений отступа в коде карты все, кроме десяти, уже были чётными. Те
    // десять (3, 5, 7, 9, 11, 15) подтянуты вверх до ближайшего чётного —
    // каждое на пункт.
    //
    // Константы под каждое значение здесь не заводятся намеренно: отступ
    // читается на месте («8 между иконкой и текстом») и словарь из пятнадцати
    // имён сделал бы вёрстку менее понятной, а не более. Система здесь — это
    // ПРАВИЛО, а не набор токенов: нечётного отступа не бывает.
    nonisolated static let spacingStep: CGFloat = 2

    static let cornerPanel: CGFloat  = 24
    static let cornerLarge: CGFloat  = 24
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat  = 12

    /// Скругление кнопки действия. Число из системы выпадало (12 и 16 рядом,
    /// а тут 14) и стояло сырым в двух местах — «Радар!» и «Стоп». Оно названо,
    /// а не подтянуто к соседям: подтягивать значит двигать вёрстку, и это
    /// решение принимается с телефоном в руках, а не компилятором.
    static let cornerControl: CGFloat = 14

    /// Круглая кнопка поверх карты — ОДИН размер на всю колонку.
    ///
    /// В одном столбце стояли 42, 44 и 46: стеклянные `CircleControl` и
    /// сплошные «3D», звук и компас из MapViewControls — два облика и три
    /// размера рядом. 44 — минимум мишени по HIG и то, что палец находит
    /// вслепую; крупнее — колонка съедает карту на маленьком iPhone.
    static let controlSize: CGFloat = 44
}

// MARK: - Типографика (rounded — «приборный» вид)

extension Font {
    // MARK: - Шкала кегля
    //
    // Было 18 разных кеглей на одних только экранах карты: 8, 9, 10, 11, 12,
    // 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 26, 30. Это не иерархия, это
    // след истории: каждый новый элемент подбирал себе размер на глаз рядом с
    // соседом, и разница в один пункт не значила ничего.
    //
    // Прижим делает сама `rounded`, а не 550 мест вызова. Так шкала перестаёт
    // быть договорённостью, которую можно забыть: девятнадцатого кегля больше
    // не существует, каким бы числом его ни попросили.
    //
    // ПЕРЕСМОТР 23 сентября — по замечанию «непонятно и много».
    //
    // Прижим работал, а шкала была плохая, и это видно в цифрах. Прогон всех
    // 550 обращений через прежние ступени [10,12,15,17,20,22,26,30]:
    //
    //   10 pt —  46 мест ( 8 %)      20 pt —  21 ( 4 %)
    //   12 pt — 256 мест (47 %)      22 pt —  13 ( 2 %)
    //   15 pt — 123 мест (22 %)      26 pt —  16 ( 3 %)
    //   17 pt —  54 мест (10 %)      30 pt —  21 ( 4 %)
    //
    // Пятьдесят пять процентов текста приложения рисовалось кеглем 12 и мельче
    // — в приложении, на которое смотрят за рулём. Мелкий текст в массе не
    // читается как «аккуратно»; он читается как «много и непонятно».
    //
    // Сверху шкала была обрезана ещё хуже: потолок 30 схлопывал всё, что
    // просили выше. Заголовок онбординга (44) и число в маленькой плитке
    // метрики (28) выходили на экран ОДНОГО размера. Разницу закладывали
    // трижды — её не было ни разу. Отношение «самое крупное / обычное»
    // получалось 30 ÷ 12 = 2,5×; приборному интерфейсу нужно вчетверо.
    //
    // Новая шкала — модульная, с постоянным отношением около 1,25. Это не
    // эстетика: постоянное отношение и есть то, из-за чего ступень читается
    // как решение, а не как случайность. Прежние 15 и 17 отличались на 13 % —
    // такую разницу глаз не видит, он видит небрежность.
    //
    // Что изменено, и каждое — ради иерархии, а не ради разнообразия:
    //   • потолок 46 — герою есть куда вырасти: 46 ÷ 12 = 3,8×;
    //   • ступени 10 больше НЕТ: нижний предел интерфейса — 12. Подпись,
    //     которую не прочесть, не экономит место, она его тратит впустую;
    //   • пары-двойники (15/17, 20/22) сведены в одну ступень каждая.
    //
    // Ступеней стало семь вместо восьми — это и есть «минималистично»:
    // меньше ступеней, и каждая отличается от соседней заметно.
    nonisolated static let typeSteps: [CGFloat] = [12, 15, 19, 24, 30, 38, 46]

    /// Ближайшая ступень шкалы; при равном расстоянии — БОЛЬШАЯ.
    /// За рулём крупнее безопаснее мельче.
    nonisolated static func snapType(_ size: CGFloat) -> CGFloat {
        guard let first = typeSteps.first, let last = typeSteps.last else { return size }
        if size <= first { return first }
        if size >= last { return last }
        var best = last
        var bestGap = CGFloat.greatestFiniteMagnitude
        for step in typeSteps {
            let gap = abs(step - size)
            // `<=` и порядок по возрастанию дают округление вверх на ничьей.
            if gap <= bestGap { bestGap = gap; best = step }
        }
        return best
    }

    // MARK: - Системное «Размер текста»
    //
    // Font.system(size:) не масштабируется ВООБЩЕ. Человек, увеличивший текст в
    // настройках iOS, не получал от приложения ничего — а это приложение, на
    // которое смотрят за рулём и в которое приходят не только двадцатилетние.
    //
    // Потолок разный по кеглю, и это не перестраховка. Цифра скорости видна с
    // вытянутой руки и без роста, а карточка вокруг неё тесная: плюс треть
    // выбьет цифру за её пределы, и «доступность» обернётся нечитаемым HUD.
    // Мелкий текст растёт полностью — он и есть нечитаемый.

    /// Насколько увеличить кегль. Чистое правило, отдельно от того, откуда
    /// взялся коэффициент, — иначе его нельзя проверить.
    ///
    /// Потолок РАСТЯНУТ, а не переключается порогом, и это починка регрессии,
    /// внесённой вместе с новой шкалой 25 сентября.
    ///
    /// Было: `size >= 20 ? 1.10 : 1.30` — ступенька в одной точке. На старой
    /// шкале она попадала в промежуток и не мешала, а на новой легла ровно
    /// между 19 и 24. При максимальном системном кегле они превращались в
    /// 25 и 26 pt — отношение 1,04, то есть **две соседние ступени
    /// становились неразличимы**. Ровно та болезнь, от которой шкалу и
    /// переделывали, только проявлялась она лишь у тех, кто увеличил текст в
    /// настройках, — то есть у тех, кому это важнее всех.
    ///
    /// Теперь между 15 и 30 потолок идёт наклоном, а выше 30 остаётся прежние
    /// 1.10: крупное по-прежнему почти не растёт (цифра видна и так, а
    /// карточка вокруг тесная), но шкала сохраняет пропорции на любом
    /// системном кегле.
    nonisolated static func typeFactor(raw: Double, size: CGFloat) -> Double {
        let small: Double = 1.30, large: Double = 1.10
        let from: CGFloat = 15, to: CGFloat = 30
        let ceiling: Double
        if size <= from {
            ceiling = small
        } else if size >= to {
            ceiling = large
        } else {
            ceiling = small + (large - small) * Double((size - from) / (to - from))
        }
        return min(max(raw, 0.9), ceiling)
    }

    #if canImport(UIKit)
    /// Коэффициент считается ОДИН раз на изменение настройки, а не на каждый
    /// `Text`: `rounded` зовут сотни раз за кадр, и поход в UIKit на каждый из
    /// них свёл бы на нет работу по изоляции пересборок.
    @MainActor private static var factorCache: (category: UIContentSizeCategory,
                                                value: Double)?
    #endif

    @MainActor private static var rawTypeFactor: Double {
        #if canImport(UIKit)
        let traits = UITraitCollection.current
        let category = traits.preferredContentSizeCategory
        if let cache = factorCache, cache.category == category { return cache.value }
        let reference: CGFloat = 17
        let scaled = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: reference, compatibleWith: traits)
        let value = reference > 0 ? Double(scaled / reference) : 1
        factorCache = (category, value)
        return value
        #else
        // watchOS: UIKit нет, а системный кегль там свой — не наше дело.
        1
        #endif
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let step = snapType(size)
        let factor = typeFactor(raw: rawTypeFactor, size: step)
        return .system(size: (step * CGFloat(factor)).rounded(),
                       weight: weight, design: .rounded)
    }

    /// Кегль ВНЕ шкалы — для подписей, растущих вместе с масштабом схемы.
    ///
    /// Единственное исключение, и оно честное: на схеме кегль вычисляется
    /// (`11 * strokeScale`), и прижим к ступеням превратил бы плавный зум в
    /// скачки размера. Шкала описывает интерфейс, а не рисунок карты.
    static func roundedFree(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
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

    /// Цвет значка НА заливке типа. Радар и тренога светлые — значок тёмный;
    /// остальные заливки тёмные — значок белый. Контраст не ниже 4,6:1.
    var glyphTint: Color {
        switch self {
        case .stationaryRadar, .tripod: return Theme.Types.darkGlyph
        default:                        return .white
        }
    }
}

/// Цвета линии маршрута ЧИСЛАМИ: из них строятся и токены `Theme.route…`
/// (SwiftUI), и строки стиля движка (EngineMapStyle.routeLayers) — один
/// источник на оба мира. Каждая пара — день/ночь; проверены PaletteTests
/// (контраст с полотном дороги обеих тем, пробка ≠ маршрут).
nonisolated enum RouteColors {
    typealias Pair = (day: UInt32, night: UInt32)
    static let body: Pair = (0x2A6FF0, 0x66A3FF)
    static let casing: Pair = (0x1E4FB8, 0x0E1A33)
    static let traveled: Pair = (0x9AA6B8, 0x4A5568)
    /// Светлая середина: белый с этой непрозрачностью поверх тела.
    static let coreAlpha: (day: Double, night: Double) = (0.38, 0.32)
    /// Стрелки направления вдоль линии: белая заливка с каймой линии.
    static let arrow: UInt32 = 0xFFFFFF
    /// Пробки: свободно / медленно / стоим.
    static let free: Pair = (0x2BA84A, 0x3CC46B)
    static let slow: Pair = (0xE8A100, 0xFFB020)
    static let jam: Pair = (0xD93025, 0xFF5A4E)
    /// Другие варианты маршрута при выборе (27.D): тот же синий род, но
    /// бледнее и без насыщенности — выбранный остаётся главным предметом
    /// карты, а другой вариант всё равно читается на асфальте любого класса
    /// (≥ 3:1 телом или каймой — PaletteTests, palette_check). Ночью тело
    /// светлее выбранного, но серое: на освещённом графите тёмная линия
    /// терялась бы (2,5:1), а отличает её от выбранной насыщенность и ширина.
    static let alternative: Pair = (0x93B4EA, 0x98ACD2)
    static let alternativeCasing: Pair = (0x46679F, 0x0E1A33)

    static func pick(_ pair: Pair, daylight: Bool) -> String { hex(daylight ? pair.day : pair.night) }

    /// «#rrggbb» — язык стиля движка.
    static func hex(_ value: UInt32) -> String { String(format: "#%06x", value & 0xFFFFFF) }

    /// «rgba(255,255,255,a)» — светлая середина для стиля движка.
    static func core(daylight: Bool) -> String {
        "rgba(255,255,255,\(daylight ? coreAlpha.day : coreAlpha.night))"
    }
}


//
//  ActivityIntents.swift
//  RadarMap
//
//  Кнопки на плашке поездки (план 19.10, 9.1б): «Радар!» и «Звук» прямо на
//  экране блокировки — телефон в держателе, разблокировать его ради одной
//  отметки значит смотреть в экран вместо дороги.
//
//  Файл общий для приложения и расширения виджетов: кнопке на плашке нужен
//  тип намерения (расширение), а выполняет `LiveActivityIntent` система в
//  процессе ПРИЛОЖЕНИЯ (поднимет его в фоне, если нужно). Логика отметки и
//  тишины живёт в приложении — расширение о ней не знает и знать не должно:
//  вторая копия `quickReport` разошлась бы с первой на первой же правке
//  защиты от дублей. Поэтому `perform` только зовёт исполнителя, которого
//  приложение регистрирует в `AppEnvironment.init`; в расширении он nil и
//  не нужен.
//

#if os(iOS)
import AppIntents
import os

/// Что попросили с плашки.
nonisolated enum ActivityAction: Sendable {
    case report
    /// «Отменить» последнюю отметку, пока открыто окно (02.11).
    case cancelReport
    case toggleSound
    /// «Звук» из Пункта управления: значение, а не переключение — кнопка и
    /// приложение могут разойтись на нажатие.
    case setSound(on: Bool)
}

/// Исполнитель кнопок плашки — ставит приложение (одно присваивание за
/// процесс, см. AppEnvironment.init).
@MainActor
enum ActivityActions {
    static var perform: ((ActivityAction) async -> Void)?

    /// Исполнителя нет — нажатие пропало бы молча; сказать об этом в журнал
    /// (Log приложения сюда не доходит: файл общий с расширением).
    static func run(_ action: ActivityAction) async {
        guard let perform else {
            Logger(subsystem: "uz.radarmap.ios", category: "alerts")
                .error("Кнопка плашки без исполнителя: \(String(describing: action), privacy: .public)")
            return
        }
        await perform(action)
    }
}

/// «Радар!» с плашки — та же дверь, что у кнопки на карте и в CarPlay:
/// тренога по умолчанию (выбора типа на плашке нет), «Отменить» — после.
struct ActivityReportIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Радар!"
    static let description = IntentDescription("Отмечает треногу в текущей точке.")
    /// В «Командах» уже есть «Радар здесь» с фразой для Siri — второй такой
    /// пункт был бы шумом.
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ActivityActions.run(.report)
        return .result()
    }
}

/// «Отменить» на месте «Радар!» — пока открыто окно отмены.
struct ActivityCancelReportIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Отменить"
    static let description = IntentDescription("Убирает только что поставленную отметку.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ActivityActions.run(.cancelReport)
        return .result()
    }
}

/// «Звук» с плашки — та же тишина, что у кнопки с динамиком на карте:
/// молчат и сигналы, и голос, а прежний режим голоса возвращается.
struct ActivitySoundIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Звук"
    static let description = IntentDescription("Выключает или возвращает звук и голос оповещений.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ActivityActions.run(.toggleSound)
        return .result()
    }
}

/// «Радар!» в Пункте управления и на кнопке действия. Вне поездки — отказ
/// голосом, как у всех удалённых входов.
struct ControlRadarIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Радар!"
    static let description = IntentDescription("Отмечает радар в текущей точке.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ControlBridge.run(.report)
        return .result()
    }
}

struct ControlSoundIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Звук"
    static let description = IntentDescription("Выключает или возвращает звук и голос оповещений.")
    static let isDiscoverable = false

    @Parameter(title: "Звук включён") var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ControlBridge.run(value ? .soundOn : .soundOff)
        return .result()
    }
}

/// Старт и стоп открывают приложение: GPS поездки запускается только оттуда,
/// а у стопа остаётся видимый итог.
struct ControlTripIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Поездка"
    static let description = IntentDescription("Начинает или заканчивает поездку.")
    static let isDiscoverable = false

    @Parameter(title: "Поездка идёт") var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(value ? TripLink.ownStartURL : TripLink.ownEndURL))
    }
}
#endif

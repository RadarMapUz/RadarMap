//
//  TripBackup.swift
//  RadarMap
//
//  Копия своих данных: выгрузить в файл и вернуть на новом телефоне.
//
//  Зачем это вообще. Поездки, проезды камер, рейтинг и пожизненные счётчики
//  живут ТОЛЬКО на устройстве и нигде больше не продублированы — так задумано,
//  сервер про перемещения человека не знает и знать не должен. Обратная
//  сторона у этого одна и тяжёлая: смена телефона, сброс, случайное удаление —
//  и месяцы истории исчезают без следа. Приложение, которое считает рейтинг за
//  год и «сколько штрафов вы не получили», обязано давать способ это сохранить.
//
//  СЛИЯНИЕ, А НЕ ЗАМЕНА. Восстановление на телефоне, где уже есть поездки, не
//  имеет права ничего стирать: человек мог начать ездить до того, как вспомнил
//  про копию. Поэтому импорт всегда объединяет, и правила объединения выбраны
//  так, чтобы в спорном случае данные не терялись:
//
//  - Поездки — по идентификатору; при совпадении остаётся та, что уже на
//    телефоне (она новее по определению: файл был снят раньше).
//  - Дневные сводки — по дню; при совпадении берётся БОЛЕЕ ПОЛНАЯ строка
//    (больше поездок). Пересобирать сводки из истории нельзя: они переживают
//    вычистку старых записей и хранят месяцы, которых в истории уже нет.
//  - Пожизненные счётчики — максимум по каждому полю. Они монотонны, и
//    максимум — единственный выбор, при котором ничего не убывает.
//  - Свои камеры — объединение по идентификатору; скрытые — объединение
//    множеств.
//
//  Формат самоописан: версия схемы и метка приложения. Чужой или будущий файл
//  распознаётся до того, как что-то будет изменено, — импорт либо проходит
//  целиком, либо не начинается.
//

import Foundation

/// Содержимое файла копии.
nonisolated struct TripBackup: Codable {
    /// Метка приложения: отличает наш файл от любого другого JSON.
    var app = TripBackup.marker
    /// Версия схемы. Растёт при несовместимом изменении; читатель обязан
    /// отказаться от того, чего не понимает, а не разобрать наполовину.
    var schema = TripBackup.currentSchema
    /// Когда снята — показываем в подтверждении, чтобы человек видел, что
    /// восстанавливает.
    var createdAt = Date()
    /// Версия приложения, снявшего копию: пригодится при разборе жалоб.
    var appVersion = ""

    var history: [TripRecord] = []
    var days: [TripDay] = []
    var lifetime = LifetimeStats()
    var customCameras: [Camera] = []
    var hiddenCameraIDs: [Int] = []

    static let marker = "radarmap.backup"
    static let currentSchema = 1

    /// Файл наш и понятен этой версии.
    var isReadable: Bool { app == Self.marker && schema <= Self.currentSchema }

    /// Пусто — восстанавливать нечего; предупредим вместо молчаливого успеха.
    var isEmpty: Bool {
        history.isEmpty && days.isEmpty && lifetime.isEmpty
            && customCameras.isEmpty && hiddenCameraIDs.isEmpty
    }

    /// Короткая сводка для экрана подтверждения: человек должен видеть, что
    /// именно он собирается влить.
    var summary: String {
        // Две строки каталога, а не одна с двумя числами: у каждого числа
        // своя форма («1 поездка · 3 дня», 6.11).
        String(localized: "\(history.count) поездок") + " · " + String(localized: "\(days.count) дней")
    }
}

/// Правила слияния — чистые и потому проверяемые тестом.
nonisolated enum TripBackupMerge {

    /// Итог объединения файла с тем, что уже на устройстве.
    struct Result {
        var history: [TripRecord]
        var days: [TripDay]
        var lifetime: LifetimeStats
        var customCameras: [Camera]
        var hiddenCameraIDs: Set<Int>
        /// Сколько записей реально добавилось — это и показываем человеку.
        var addedTrips: Int
        var addedDays: Int
    }

    static func merge(_ backup: TripBackup,
                      history: [TripRecord],
                      days: [TripDay],
                      lifetime: LifetimeStats,
                      customCameras: [Camera],
                      hiddenCameraIDs: Set<Int>,
                      calendar: Calendar = .current) -> Result {
        // --- поездки: своё выигрывает, чужое дополняет ---
        var byID: [Double: TripRecord] = [:]
        for record in backup.history { byID[record.id] = record }
        for record in history {
            byID[record.id] = record          // то, что на телефоне, новее
        }
        let mergedHistory = byID.values.sorted { $0.startedAt > $1.startedAt }
        let addedTrips = mergedHistory.count - history.count

        // --- дни: побеждает более полная строка ---
        var byDay: [Date: TripDay] = [:]
        for day in backup.days { byDay[day.day] = day }
        for day in days {
            if let existing = byDay[day.day], existing.trips > day.trips { continue }
            byDay[day.day] = day
        }
        // Строка дня, у которой все поездки есть в объединённой истории, —
        // свёртка из них (S15, 20.10): «полнее» с одной стороны теряла
        // поездки другой — в списке три поездки дня, а в итогах две. Если
        // часть поездок дня уже вырезана из истории, свёртка короче строк —
        // тогда остаётся строка (у старых дней правды больше нигде нет).
        let recordsByDay = Dictionary(grouping: mergedHistory) { calendar.startOfDay(for: $0.startedAt) }
        for key in Array(byDay.keys) {
            guard let records = recordsByDay[key],
                  let rebuilt = TripDayBook.rebuilt(from: records, calendar: calendar).first,
                  rebuilt.trips >= (byDay[key]?.trips ?? 0) else { continue }
            byDay[key] = rebuilt
        }
        let mergedDays = byDay.values.sorted { $0.day > $1.day }

        return Result(history: mergedHistory,
                      days: mergedDays,
                      lifetime: maxed(lifetime, backup.lifetime),
                      customCameras: mergedCameras(customCameras, backup.customCameras),
                      hiddenCameraIDs: hiddenCameraIDs.union(backup.hiddenCameraIDs),
                      addedTrips: max(0, addedTrips),
                      addedDays: max(0, mergedDays.count - days.count))
    }

    /// Пожизненные счётчики монотонны: максимум по каждому полю — единственная
    /// операция, при которой ничего не убывает. Складывать нельзя — копия и
    /// устройство пересекаются, и сумма удвоила бы общий пробег.
    static func maxed(_ a: LifetimeStats, _ b: LifetimeStats) -> LifetimeStats {
        var result = LifetimeStats()
        result.trips = max(a.trips, b.trips)
        result.distanceMeters = max(a.distanceMeters, b.distanceMeters)
        result.camerasPassed = max(a.camerasPassed, b.camerasPassed)
        result.camerasInLimit = max(a.camerasInLimit, b.camerasInLimit)
        result.savedFinesSum = max(a.savedFinesSum, b.savedFinesSum)
        result.riskFinesSum = max(a.riskFinesSum, b.riskFinesSum)
        result.cleanStreak = max(a.cleanStreak, b.cleanStreak)
        result.bestStreak = max(a.bestStreak, b.bestStreak)
        return result
    }

    private static func mergedCameras(_ own: [Camera], _ imported: [Camera]) -> [Camera] {
        var byID: [Int: Camera] = [:]
        for camera in imported { byID[camera.id] = camera }
        for camera in own { byID[camera.id] = camera }
        return byID.values.sorted { $0.id < $1.id }
    }
}

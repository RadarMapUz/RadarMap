//
//  AppEnvironment+History.swift
//  RadarMap
//
//  «Удалить всю историю» (15.3, 15.6) — в композиционном корне: история
//  лежит в TripStats, а посчитанное из неё — в нескольких местах (дорога на
//  работу, смены, выученные места, «свои камеры», «Где машина», недавние
//  места, виджет), и стереть одно без другого значит оставить историю жить
//  в производных.
//

import Foundation
import os

extension AppEnvironment {

    /// Стирает с телефона историю поездок и всё, что из неё посчитано:
    /// месяцы с индексом и отложенными копиями, дневные итоги, «За всё
    /// время» с охватом предупреждений, подробные треки регистратора (всё —
    /// TripStats.clearHistory), журнал и профиль дороги на работу (через
    /// onRecordsErased), журнал смен, выученные Дом и Работу, знакомые камеры
    /// (умная тишина), точку «Где машина», недавние места, журнал заправок и
    /// зарядок (21.6: даты и пробег с панели — та же история) и цифры виджета.
    /// Настройки, топливо, заданные вручную места, добавленные и скрытые
    /// камеры, внесённые штрафы остаются. Лист подтверждения перечисляет
    /// `erasedLines` и `keptLines` — они обязаны говорить ровно это.
    ///
    /// Идущую поездку не трогает: её контрольная точка и последний фикс за
    /// рулём — уже не история, а поездка, начатая до удаления; закончившись,
    /// она сохранится и поставит свою точку парковки, как любая другая.
    func deleteAllHistory() {
        // До чтения истории стирать нечего честно: диск лёг бы поверх (S9).
        guard trip.isLoaded, trip.isLifetimeTrusted else { return }
        trip.clearHistory()
        clearWorkShifts()
        Storage.remove(.mergeSuggestDismissedID)
        // Конец прошлой поездки и цели маршрутов — те же координаты из
        // истории (15.6). Сразу и в памяти: чип «Машина · 330 м» и строки
        // «Недавние» пропадают, не дожидаясь перезапуска.
        location.forgetParkedCar()
        settings.recentPlaces = []
        energyJournal.eraseAll()
        // Память своих дорог (31E) — те же места, что в треках.
        roadMemory.eraseRoads()
        // Копия в iCloud — тоже (27.F): поездки и сводка сразу или при
        // первой сети; журнал и недавние места уйдут надгробиями сверкой.
        cloud.historyErased()
        // Из пустой истории — пусто; следом дорога на работу и смены.
        refreshLearnedPlaces()
        location.refreshFamiliarCameras()
        refreshWidgetSnapshot()
        Log.trips.notice("история поездок удалена целиком по просьбе человека")
    }

    /// Строка листа подтверждения: значок и что именно.
    struct ErasureLine: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }

    /// Что сотрёт `deleteAllHistory` — ровно это, без «и т. п.». Правишь
    /// удаление — правь список.
    static var erasedLines: [ErasureLine] {
        [ErasureLine(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                     text: String(localized: "Поездки с треками и проездами камер")),
         ErasureLine(symbol: "chart.bar.fill",
                     text: String(localized: "Итоги по дням и «За всё время»")),
         ErasureLine(symbol: "record.circle",
                     text: String(localized: "Подробные треки регистратора")),
         ErasureLine(symbol: "briefcase.fill",
                     text: String(localized: "Дорога на работу и журнал смен")),
         ErasureLine(symbol: "sparkles",
                     text: String(localized: "Выученные Дом и Работа, знакомые камеры")),
         ErasureLine(symbol: "car.fill",
                     text: String(localized: "Где оставили машину")),
         ErasureLine(symbol: "clock.arrow.circlepath",
                     text: String(localized: "Недавние места")),
         ErasureLine(symbol: "road.lanes",
                     text: String(localized: "Память своих дорог и новые камеры на них")),
         ErasureLine(symbol: "list.bullet.rectangle",
                     text: String(localized: "Журнал заправок и зарядок")),
         ErasureLine(symbol: "square.grid.2x2.fill",
                     text: String(localized: "Цифры виджета"))]
    }

    /// Строка про iCloud (27.F) — только когда копия там есть или может быть.
    static var cloudErasedLine: ErasureLine {
        ErasureLine(symbol: "icloud.slash", text: String(localized: "Копия истории в iCloud"))
    }

    /// Что сотрётся на самом деле — с копией в iCloud, если она есть.
    var erasedLinesNow: [ErasureLine] {
        cloud.isEnabled || cloud.mayHaveCloudCopy ? Self.erasedLines + [Self.cloudErasedLine] : Self.erasedLines
    }

    /// Что `deleteAllHistory` не трогает — то, что человек задал сам.
    static var keptLines: [ErasureLine] {
        [ErasureLine(symbol: "gearshape.fill", text: String(localized: "Настройки")),
         ErasureLine(symbol: "fuelpump.fill", text: String(localized: "Расход и цены топлива")),
         ErasureLine(symbol: Icon.myPlaces, text: String(localized: "Места, заданные вручную")),
         ErasureLine(symbol: Icon.ownCamera, text: String(localized: "Добавленные вами камеры")),
         // Штраф, чья поездка стёрта, остаётся «без поездки в истории».
         ErasureLine(symbol: "doc.text", text: String(localized: "Полученные штрафы")),
         ErasureLine(symbol: "folder.fill", text: String(localized: "Копии в «Файлах»"))]
    }
}

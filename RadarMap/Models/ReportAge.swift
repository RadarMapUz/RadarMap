//
//  ReportAge.swift
//  RadarMap
//
//  Сколько отметке водителей минут — в карточке и в баннере машины.
//
//  Правило владельца (02.11): тренога — это «сейчас», а не «здесь». Её
//  ставят и убирают в любое время, и «отмечена 10 минут назад» против «два
//  часа назад» меняет решение водителя сильнее, чем число голосов.
//  Подтверждённая — «с 14:05»: она стоит, и важно, с какого времени.
//
//  Время отметки — `created` сервера с поправкой на расхождение часов
//  (MobileCameraService.clockSkew). Старый сервер поля не шлёт (там эпоха):
//  вместо возраста вышло бы «55 лет назад» — молчим.
//
//  Чистая логика, покрыто ReportAgeTests.
//

import Foundation

nonisolated enum ReportAge {

    /// Полных минут с отметки; nil — время неизвестно.
    static func minutes(since created: Date?, now: Date) -> Int? {
        guard let created, created.timeIntervalSince1970 > 0 else { return nil }
        return max(0, Int(now.timeIntervalSince(created) / 60))
    }

    /// Строка карточки: «Отмечена 12 мин назад» / «Подтверждена · с 14:05».
    static func card(created: Date?, confirmed: Bool, now: Date) -> String? {
        guard let minutes = minutes(since: created, now: now), let created else { return nil }
        if confirmed {
            return String(format: String(localized: "Подтверждена · с %@"), NumberFormat.clock(created))
        }
        if minutes < 1 { return String(localized: "Отмечена только что") }
        if minutes < 60 {
            return String(format: String(localized: "Отмечена %lld мин назад"), minutes)
        }
        return String(format: String(localized: "Отмечена в %@"), NumberFormat.clock(created))
    }

    /// Подзаголовок баннера машины — от длинного к короткому (машина берёт
    /// первый, что влезет). nil — время неизвестно, подзаголовок прежний.
    static func banner(created: Date?, confirmed: Bool, now: Date) -> [String]? {
        guard let minutes = minutes(since: created, now: now), let created else { return nil }
        if confirmed {
            let since = String(format: String(localized: "с %@"), NumberFormat.clock(created))
            return [String(format: String(localized: "Подтверждена · %@"), since), since]
        }
        let age = minutes < 1 ? String(localized: "только что")
                              : String(format: String(localized: "%lld мин"), minutes)
        let ago = minutes < 1 ? age : String(format: String(localized: "%lld мин назад"), minutes)
        return [String(format: String(localized: "Отметка водителей · %@"), age), ago]
    }
}

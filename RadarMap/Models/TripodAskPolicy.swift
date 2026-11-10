//
//  TripodAskPolicy.swift
//  RadarMap
//
//  Кого спрашивать «Тренога ещё стоит?» (пункт 82). Ответ нужнее всего там,
//  где отметку давно не подтверждали или где кто-то сказал «Уже нет»; только
//  что подтверждённую не спрашиваем — не мучить людей вопросом, ответ на
//  который уже есть. Кроме редкой выборки: без неё не узнать, врут ли
//  «свежие» отметки (доля «Уже нет» среди только что подтверждённых).
//
//  Чистая логика, покрыто TripodAskPolicyTests.
//

import Foundation

nonisolated enum TripodAskPolicy {

    /// Стоит ли спрашивать об этой отметке. `salt` — постоянное на устройство
    /// число: выборка детерминирована (тот же ответ на каждом фиксе) и у
    /// разных водителей падает на разные отметки.
    static func worthAsking(id: Int, fresh: TripodFreshness.Info?, now: Date, salt: Int) -> Bool {
        guard let fresh, fresh.trust != nil, fresh.doubted == 0,
              let last = fresh.lastConfirmed, last.timeIntervalSince1970 > 0,
              now.timeIntervalSince(last) < AppConfig.tripodAskSkipFreshSeconds else { return true }
        return sampled(id: id, salt: salt)
    }

    /// Одна из `tripodAskSampleEvery` отметок.
    static func sampled(id: Int, salt: Int) -> Bool {
        var mixed = UInt64(truncatingIfNeeded: id) &* 0x9E37_79B9_7F4A_7C15
        mixed ^= UInt64(truncatingIfNeeded: salt)
        mixed = (mixed ^ (mixed >> 31)) &* 0xBF58_476D_1CE4_E5B9
        return mixed % UInt64(max(1, AppConfig.tripodAskSampleEvery)) == 0
    }

    /// Отметки, о которых сейчас не спрашиваем (дополнение к своим).
    static func skipped(_ cameras: [Camera], now: Date, salt: Int) -> Set<Int> {
        Set(cameras.filter { !worthAsking(id: $0.id, fresh: $0.mobileFresh, now: now, salt: salt) }.map(\.id))
    }

    /// Постоянная соль из анонимного id устройства (FNV-1a: hashValue Swift
    /// меняется между запусками).
    static func salt(from deviceID: String) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in deviceID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(truncatingIfNeeded: hash)
    }
}

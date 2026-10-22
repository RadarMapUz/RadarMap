//
//  OverspeedThreshold.swift
//  RadarMap
//
//  При каком превышении считать, что водитель превышает.
//
//  Порог был один на все случаи и равен допуску из настроек — по умолчанию 5.
//  Столько же составляет штрафной допуск (FineSchedule.toleranceKmh): камеры
//  на практике не фиксируют первые пять километров в час. Совпадение этих двух
//  чисел и есть дефект: в зоне 60 фиксация начинается с 66, а предупреждение
//  звучало ровно там же — то есть приходило ВМЕСТЕ со штрафом.
//
//  Предупреждение, приходящее одновременно с событием, от которого оно
//  предупреждает, бесполезно. Поэтому у камеры порог становится жёстче
//  штрафного, а вдали от камер остаётся мягким: там это совет, и дёргать
//  человека за километр в час незачем.
//
//  Чистое правило — покрыто OverspeedThresholdTests.
//

import Foundation

nonisolated enum OverspeedThreshold {
    /// Насколько нужно превысить лимит, чтобы это считалось превышением.
    static func kmh(cameraAhead: Bool, userTolerance: Double) -> Double {
        guard cameraAhead else { return userTolerance }
        // Никогда не мягче настройки: человек, поставивший допуск 0, просил
        // говорить раньше, а не позже.
        return min(userTolerance,
                   max(0, FineSchedule.toleranceKmh - AppConfig.cameraOverspeedWarnMarginKmh))
    }

    /// Скорость, выше которой — превышение: лимит плюс порог. Одна функция
    /// для `SpeedLimitService.isOverspeeding` и всего, что по нему красится.
    static func line(limitKmh: Int, cameraAhead: Bool, userTolerance: Double) -> Double {
        Double(limitKmh) + kmh(cameraAhead: cameraAhead, userTolerance: userTolerance)
    }

    /// Краснеет ли живая скорость и знак лимита рядом с ней — телефон, док
    /// CarPlay, плитка приборки: ОДНО правило, превышение выше порога
    /// (`isOverspeeding`). До 22.10 цифра в доке CarPlay красилась по шкале
    /// штрафа (`Theme.speedLevel`), а знак рядом — по порогу: 64 в зоне 60
    /// при допуске 5 давали красный знак у белой цифры (отчёт качества, п. 11).
    /// Без показанного лимита сравнивать не с чем — не краснеет ничего.
    static func showsOverspeed(limitShown: Int?, isOverspeeding: Bool) -> Bool {
        limitShown != nil && isOverspeeding
    }

    /// Штраф на этой скорости уже заработан — «поздно», а не «осторожно».
    static func isFineEarned(speedKmh: Double, limitKmh: Int) -> Bool {
        speedKmh - Double(limitKmh) > FineSchedule.toleranceKmh
    }
}

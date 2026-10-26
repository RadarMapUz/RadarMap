//
//  AppConfig+Itogi.swift
//  RadarMap
//
//  Константы «Итогов» 31E: сравнение периодов, время в пробках, превышения
//  вне камер, польза отметок, новые камеры на своих дорогах, цель недели,
//  выгрузка периода. Отдельным файлом, а не секцией AppConfig.swift: тот
//  правят параллельно несколько веток, и каждая новая секция там — конфликт.
//

import Foundation
import CoreLocation

extension AppConfig {

    // Процент к прошлому периоду — WidgetWeek.comparablePercent (Shared/):
    // одно правило с виджетом, а виджет AppConfig не видит.

    // MARK: - Время в пробках (TrafficTime, 31E)

    /// Отрезок трека медленнее этого — «ползём». 10 км/ч: в городском потоке
    /// так не едут даже на светофорной волне, а пешеходный шаг — уже пробка.
    nonisolated static let jamSpeedKmh = 10.0
    /// Пробка — от трёх минут подряд. Красный свет со стоянием длится до
    /// двух: короче — светофор, а не пробка, и «20 минут пробок» за неделю,
    /// набранные светофорами, были бы враньём про город.
    nonisolated static let jamMinRunSeconds: TimeInterval = 180
    /// Отрезок между точками трека дольше этого — разрыв (тоннель, потеря
    /// GPS, стоянка без признанной остановки), а не пробка.
    nonisolated static let jamMaxSegmentSeconds: TimeInterval = 600
    /// Сколько пробок хранить в записи: больше — шум, сумма от этого не врёт
    /// заметно (короткие отбрасываются первыми).
    nonisolated static let jamMaxPerTrip = 40
    /// Клетка «где больше всего» — около квартала.
    nonisolated static let jamPlaceCellMeters: CLLocationDistance = 400
    /// Меньше этого за период карточку не показываем: две минуты пробок —
    /// не вывод, а помеха.
    nonisolated static let jamMinPeriodSeconds: TimeInterval = 300

    // MARK: - Превышения вне камер (OverLimit, 31E)

    /// «Заметно выше лимита» — на 10 км/ч и больше. Порог ниже — шум
    /// спидометра и знак, который OSM знает с ошибкой в 10 км/ч.
    nonisolated static let overLimitMarginKmh = 10.0
    /// Ближе этого к камере путь не считается: у камер своя строка
    /// («Возможные штрафы»), здесь — дорога между ними.
    nonisolated static let overLimitCameraZoneMeters: CLLocationDistance = 300
    /// Короче — разгон на обгоне, а не привычка; в места не идёт.
    nonisolated static let overLimitMinRunMeters: CLLocationDistance = 100
    nonisolated static let overLimitMaxRunsPerTrip = 40
    /// Меньше этого пути с известным лимитом — долю не называем.
    nonisolated static let overLimitMinKnownMeters: CLLocationDistance = 5_000
    nonisolated static let overLimitPlaceCellMeters: CLLocationDistance = 400

    // MARK: - Польза отметок (ReportImpact, 31E)

    /// Как часто спрашивать сервер о подтверждениях своих отметок. Сервер
    /// стирает отметку через сутки после протухания — раз в полчаса, пока
    /// приложение открыто, успеваем с запасом.
    nonisolated static let reportImpactRefreshSeconds: TimeInterval = 1800
    /// Окно счётчика: столько живёт UUID отметок — старше сервер про нас
    /// не знает, и экран честно говорит «за 30 дней».
    nonisolated static let reportImpactDays = 30

    // MARK: - Новые камеры на своих дорогах (CameraNews, 31E)

    /// Клетка памяти «где я езжу». 150 м с соседями — коридор ±225 м:
    /// камера на своей улице попадает, на параллельной через квартал — нет.
    nonisolated static let roadCellMeters: CLLocationDistance = 150
    /// Сколько дней помнить дорогу. Два месяца — дача раз в месяц тоже «своя».
    nonisolated static let roadMemoryDays = 60
    /// Сколько дней показывать новость о камере.
    nonisolated static let cameraNewsShowDays = 30
    /// Больше новых id за раз — это пересборка базы, а не новые камеры:
    /// сказать «у вас 900 новых камер» было бы неправдой.
    nonisolated static let cameraNewsMaxBatch = 150
    /// Строк камер в карточке: остальные — числом в заголовке.
    nonisolated static let cameraNewsRows = 5

    // MARK: - Цель недели (WeeklyGoal, 31E)

    /// Сколько недель назад искать серию.
    nonisolated static let weeklyGoalLookbackWeeks = 52

    // MARK: - Выгрузка периода (PeriodExport, 31E)

    /// Район для «откуда/куда» — по ближайшей камере базы не дальше этого:
    /// у камеры в базе записан район («Yunusobod tumani»), своего справочника
    /// районов на телефоне нет. Дальше — без района, а не чужой район.
    nonisolated static let exportDistrictMaxMeters: CLLocationDistance = 2_500
}

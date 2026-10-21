//
//  CarPlayCluster.swift
//  RadarMap
//
//  Приборка (CPTemplateApplicationInstrumentClusterScene, iOS 15.4): что
//  рисовать в окне кластера и когда там вообще жить карте.
//
//  Машина сама говорит, рисовать ли приложению знак лимита и компас
//  (`CPInstrumentClusterController.speedLimitSetting` / `compassSetting`):
//  у одной машины свой знак лимита стоит рядом со спидометром, и второй наш
//  был бы двумя знаками, у другой его нет — и тогда наш на своём месте.
//  Скорость не рисуем никогда: спидометр на приборке — машины.
//
//  Карта в приборке — вторая карта на движке одновременно с экраном машины
//  (docs/crash_carplay_memory.md), поэтому она живёт строже двух других:
//  только пока окно кластера подключено и сцена на экране, и не на горячем
//  телефоне — там первыми уходят украшения, а голос и экран машины
//  предупреждают о камерах как прежде. Чистые решения, CarPlayClusterTests.
//

import Foundation

nonisolated enum CarPlayCluster {

    /// Настройка машины для знака лимита или компаса — зеркало
    /// `CPInstrumentClusterSetting` без CarPlay в чистом коде.
    enum Setting: Equatable, Sendable {
        /// Машина не сказала.
        case unspecified
        /// Машина просит рисовать.
        case enabled
        /// Машина просит не рисовать: у неё своё.
        case disabled
        /// По выбору водителя — то есть по настройке приложения.
        case userPreference
    }

    /// Рисовать ли свой знак лимита. «Не рисуй» от машины — закон: у неё
    /// свой знак, два одинаковых рядом читаются как два разных лимита.
    /// В остальных случаях — по настройке «Ограничения скорости»: выключенные
    /// лимиты не должны появиться на приборке, а «машина не сказала» —
    /// не повод прятать самое полезное антирадару после камеры.
    static func drawsSpeedLimit(_ setting: Setting, limitsEnabled: Bool) -> Bool {
        setting != .disabled && limitsEnabled
    }

    /// Рисовать ли свой компас — только когда машина просит. Своей настройки
    /// компаса у приложения нет, а окно кластера по правилам CarPlay — карта,
    /// без лишних элементов поверх.
    static func drawsCompass(_ setting: Setting) -> Bool {
        setting == .enabled
    }

    /// Ставить ли содержимое (хост SwiftUI с картой) в окно кластера.
    /// Окна нет — некуда; сцена не на экране — картинку никто не видит;
    /// приложение в фоне — MapLibre, созданный в фоне, стартует «спящим»
    /// (те же правила, что у экрана машины и плитки, 2.2.6).
    static func installsContent(windowConnected: Bool, onScreen: Bool, appInBackground: Bool) -> Bool {
        windowConnected && onScreen && !appInBackground
    }

    /// Рисовать ли карту внутри поставленного содержимого. На горячем
    /// телефоне (`.minimal`) приборка остаётся без карты первой: это третья
    /// по важности картинка после голоса и экрана машины.
    static func showsMap(onScreen: Bool, performance: PerformanceMode) -> Bool {
        onScreen && performance != .minimal
    }

    /// Подпись приборки, когда ведения нет (`inactiveDescriptionVariants`):
    /// от длинной к короткой — машина берёт первую, что влезает. Без
    /// обещаний, которых сейчас может и не быть: «предупреждаю» — только в
    /// поездке, без неё — что на карте.
    static func inactiveDescription(tripActive: Bool) -> [String] {
        tripActive
            ? [String(localized: "RadarMap: предупреждаю о камерах"),
               String(localized: "Предупреждаю о камерах"),
               String(localized: "Камеры")]
            : [String(localized: "RadarMap: камеры на карте"),
               String(localized: "Камеры на карте"),
               String(localized: "Камеры")]
    }
}

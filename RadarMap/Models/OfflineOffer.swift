//
//  OfflineOffer.swift
//  RadarMap
//
//  «Скачать карту вашей области?» — одно предложение за жизнь приложения.
//
//  Скачивание — выбор человека, а не обязанность: камеры предупреждают и
//  без него, офлайн-карта — только картинка на трассе без связи. Поэтому
//  приложение спрашивает ОДИН раз, в спокойный момент, и любой ответ —
//  «Скачать» или «Не сейчас» — закрывает вопрос навсегда. Дальше область
//  качают в Настройки → Карта → Офлайн-карты, если захотят.
//
//  Спокойный момент — это:
//  - онбординг позади (человеку и так задали достаточно вопросов);
//  - карта — наша (на карте Apple офлайн-файлы ничего не меняют);
//  - не за рулём: решение про мегабайты не принимают на ходу;
//  - Wi-Fi, а не сотовая: сотни мегабайт по мобильной сети предлагать нельзя;
//  - область известна и ещё не скачана и не качается.
//
//  Чистое решение — покрыто OfflineOfferTests.
//

import CoreLocation

nonisolated enum OfflineOffer {

    struct Situation: Equatable {
        var onboarded: Bool
        var answered: Bool
        var ownMap: Bool
        var driving: Bool
        var online: Bool
        var expensiveNetwork: Bool
        /// Область найдена в каталоге и ещё не скачана и не качается.
        var regionAvailable: Bool
    }

    static func shouldOffer(_ s: Situation) -> Bool {
        s.onboarded && !s.answered && s.ownMap && !s.driving
            && s.online && !s.expensiveNetwork && s.regionAvailable
    }

    /// Точка, по которой выбирается «ваша» область: адрес «Дом», иначе
    /// выученный дом, иначе где человек сейчас. Дом важнее текущего места:
    /// человек, открывший приложение в командировке, ездит дома.
    static func anchor(home: CLLocationCoordinate2D?, learnedHome: CLLocationCoordinate2D?,
                       current: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        home ?? learnedHome ?? current
    }
}

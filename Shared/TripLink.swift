//
//  TripLink.swift
//  RadarMap
//
//  radarmap://start-trip — единственная ссылка, которая МЕНЯЕТ состояние:
//  постоянный GPS, запись трека, куски пробок. Открыть её может любое
//  приложение или страница (аудит 38B, L-8), поэтому старт без вопроса — только
//  по ссылке с ключом из App Group: его знают наш виджет локскрина и кнопка
//  Пункта управления, а чужое приложение прочитать группу не может. Ссылка без
//  ключа или с чужим — вопрос «Начать поездку?» в приложении. Siri, Быстрые
//  команды и кнопка действия идут не сюда, а через StartTripIntent: там
//  действие подтверждает сама система.
//

import Foundation

nonisolated enum TripLink {
    static let scheme = "radarmap"
    static let startHost = "start-trip"
    static let keyItem = "k"
    /// Ключ своих кнопок в App Group. 122 случайных бита UUID — не пароль,
    /// а метка «нажато в нашем виджете».
    static let storeKey = "link.startTripKey"

    enum Decision: Equatable, Sendable {
        /// Своя кнопка — начать сразу.
        case start
        /// Ссылка извне — спросить.
        case confirm
        /// Поездка уже идёт — ссылка её не трогает.
        case ignore
    }

    /// Ссылка для своих кнопок. Ключа нет (группа не выдана, приложение ещё
    /// не открывали) — ссылка без ключа, то есть с вопросом: так безопаснее,
    /// чем молча стартовать по ссылке, которую может собрать кто угодно.
    static func startURL(key: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = startHost
        if let key, !key.isEmpty {
            components.queryItems = [URLQueryItem(name: keyItem, value: key)]
        }
        return components.url ?? URL(string: "\(scheme)://\(startHost)")!
    }

    /// Ссылка для своих кнопок с ключом из App Group (виджет, Пункт управления).
    static var ownStartURL: URL {
        startURL(key: SharedDefaults.store?.string(forKey: storeKey))
    }

    /// Что делать со ссылкой. nil — ссылка не про старт поездки.
    static func decide(_ url: URL, expectedKey: String?, tripActive: Bool) -> Decision? {
        guard url.scheme == scheme, url.host() == startHost else { return nil }
        if tripActive { return .ignore }
        let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == keyItem }?.value
        guard let expectedKey, !expectedKey.isEmpty, given == expectedKey else { return .confirm }
        return .start
    }

    /// Ключ своих кнопок: прочитать или завести. `created` — завели сейчас, и
    /// виджеты надо перерисовать, иначе их ссылка останется без ключа.
    static func prepareKey(in store: UserDefaults?,
                           make: () -> String = { UUID().uuidString }) -> (key: String?, created: Bool) {
        guard let store else { return (nil, false) }
        if let key = store.string(forKey: storeKey), !key.isEmpty { return (key, false) }
        let key = make()
        store.set(key, forKey: storeKey)
        return (key, true)
    }
}

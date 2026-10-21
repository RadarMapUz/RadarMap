//
//  CarLinkTests.swift
//  RadarMapTests
//
//  «Только в машине» (26.2) и такси (26.3): подключение к своей машине
//  начинает поездку, отключение — заканчивает (с паузой), наушники своей
//  машиной не считаются, «Авто» с выбранной машиной не пишет чужую молча.
//

import XCTest
@testable import RadarMap

final class CarLinkTests: XCTestCase {

    private let car = CarLink.Port(uid: "AA:BB", name: "BYD Song Plus", kind: .bluetooth)
    private let buds = CarLink.Port(uid: "CC:DD", name: "AirPods Pro", kind: .bluetooth)
    private let carPlay = CarLink.Port(uid: "cp", name: "CarPlay", kind: .carPlay)
    private let speaker = CarLink.Port(uid: "spk", name: "Speaker", kind: .other)
    private var chosenCar: [CarAudioDevice] { [CarAudioDevice(uid: "AA:BB", name: "BYD Song Plus")] }

    // MARK: - Признание машины

    func testCarPlayIsAlwaysOwnCar() {
        XCTAssertTrue(CarLink.isLinked(ports: [carPlay], chosen: []))
    }

    func testBluetoothOnlyWhenChosen() {
        XCTAssertFalse(CarLink.isLinked(ports: [car], chosen: []))
        XCTAssertTrue(CarLink.isLinked(ports: [car], chosen: chosenCar))
        XCTAssertFalse(CarLink.isLinked(ports: [buds, speaker], chosen: chosenCar))
    }

    /// uid порта на другой версии iOS бывает другим — запасное совпадение по имени.
    func testNameFallbackWhenUidChanged() {
        let sameCarNewUid = CarLink.Port(uid: "XX", name: "BYD Song Plus", kind: .bluetooth)
        XCTAssertTrue(CarLink.isLinked(ports: [sameCarNewUid], chosen: chosenCar))
    }

    /// Такси в AirPods: «Я за рулём» когда-то запомнил наушники как магнитолу,
    /// и каждая поездка в такси писалась молча. Больше не признаём.
    func testHeadphonesAreNotRecognizedAsCar() {
        XCTAssertFalse(CarLink.isRecognized(ports: [buds], chosen: [], known: ["AirPods Pro"]))
        XCTAssertTrue(CarLink.isRecognized(ports: [car], chosen: [], known: ["BYD Song Plus"]),
                      "знакомая магнитола по-прежнему своя")
        XCTAssertTrue(CarLink.looksLikeHeadphones("Galaxy Buds2 Pro"))
        XCTAssertTrue(CarLink.looksLikeHeadphones("Наушники Зафара"))
        XCTAssertFalse(CarLink.looksLikeHeadphones("Chevrolet Cobalt"))
        XCTAssertFalse(CarLink.looksLikeHeadphones("CAR MULTIMEDIA"))
    }

    func testCandidatesDeduplicateByName() {
        let hfp = CarLink.Port(uid: "AA:BB-hfp", name: "BYD Song Plus", kind: .bluetooth)
        XCTAssertEqual(CarLink.candidates([car, hfp, speaker, buds]).map(\.name),
                       ["BYD Song Plus", "AirPods Pro"])
    }

    // MARK: - Старт и стоп по подключению

    private func state(_ mode: TripStartMode, linked: Bool, was: Bool, trip: Bool = false,
                       fromLink: Bool = false, passenger: Bool = false,
                       motion: Bool = false) -> CarLink.State {
        .init(mode: mode, linked: linked, wasLinked: was, tripActive: trip,
              tripFromLink: fromLink, passenger: passenger, motionDriving: motion)
    }

    func testCarOnlyStartsOnConnect() {
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: true, was: false)), .start)
    }

    func testCarOnlyStopsOnDisconnectOnlyForLinkTrip() {
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: false, was: true,
                                              trip: true, fromLink: true)), .scheduleStop)
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: false, was: true,
                                              trip: true, fromLink: false)), .none,
                       "поездку кнопкой без машины закрывает только человек")
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: false, was: true)), .none)
    }

    func testConnectDuringTripAdopts() {
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: true, was: false, trip: true)), .adopt)
    }

    func testPassengerConnectDoesNotStart() {
        XCTAssertEqual(CarLink.onChange(state(.carOnly, linked: true, was: false, passenger: true)), .none)
    }

    /// «Умный»: CarPlay по воздуху подключился после автостарта CoreMotion,
    /// который спросил и не начал, — теперь ясно, что машина своя.
    func testSmartStartsWhenCarAppearsWhileDriving() {
        XCTAssertEqual(CarLink.onChange(state(.smart, linked: true, was: false, motion: true)), .start)
        XCTAssertEqual(CarLink.onChange(state(.smart, linked: true, was: false, motion: false)), .none,
                       "сел в машину и стоит — старт по движению, как раньше")
        XCTAssertEqual(CarLink.onChange(state(.manual, linked: true, was: false, motion: true)), .none)
    }

    func testOtherModesNeverStopOnDisconnect() {
        XCTAssertEqual(CarLink.onChange(state(.auto, linked: false, was: true,
                                              trip: true, fromLink: true)), .none,
                       "в «Авто» конец поездки решает CoreMotion")
    }

    // MARK: - Автостарт CoreMotion (такси)

    func testAutoStartDecision() {
        XCTAssertEqual(CarLink.autoStart(mode: .smart, recognized: false, passenger: false,
                                         ownCarConfigured: false), .askOnly)
        XCTAssertEqual(CarLink.autoStart(mode: .smart, recognized: true, passenger: false,
                                         ownCarConfigured: false), .start)
        XCTAssertEqual(CarLink.autoStart(mode: .auto, recognized: false, passenger: false,
                                         ownCarConfigured: false), .startAndAsk,
                       "«Авто» без выбранной машины — как раньше")
        XCTAssertEqual(CarLink.autoStart(mode: .auto, recognized: false, passenger: false,
                                         ownCarConfigured: true), .askOnly,
                       "такси: своя машина известна, её нет — спросить, а не писать")
        XCTAssertEqual(CarLink.autoStart(mode: .carOnly, recognized: true, passenger: false,
                                         ownCarConfigured: true), .ignore,
                       "«Только в машине» CoreMotion не стартует вовсе")
        XCTAssertEqual(CarLink.autoStart(mode: .auto, recognized: true, passenger: true,
                                         ownCarConfigured: false), .ignore)
    }

    // MARK: - Предложение режима

    func testOfferOnceAfterCarPlay() {
        XCTAssertTrue(CarLink.shouldOffer(carPlaySeen: true, mode: .smart, answered: false))
        XCTAssertFalse(CarLink.shouldOffer(carPlaySeen: false, mode: .smart, answered: false))
        XCTAssertFalse(CarLink.shouldOffer(carPlaySeen: true, mode: .smart, answered: true))
        XCTAssertFalse(CarLink.shouldOffer(carPlaySeen: true, mode: .carOnly, answered: false))
    }

    func testModeFlags() {
        XCTAssertFalse(TripStartMode.carOnly.usesMotion, "CoreMotion не нужен — батарея")
        XCTAssertTrue(TripStartMode.smart.usesMotion)
        XCTAssertFalse(TripStartMode.manual.usesMotion)
    }
}

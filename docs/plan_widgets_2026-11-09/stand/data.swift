import SwiftUI
import WidgetKit

// Четверг 12.11.2026, текущая неделя. Часовой пояс — машины.
let cal = Calendar.current
let thu0805: Date = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 8, minute: 5))!
let thu1830: Date = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18, minute: 30))!
let weekStart = cal.dateInterval(of: .weekOfYear, for: thu0805)!.start

typealias Snap = SharedDefaults.Snapshot

let snapFull = Snap(weekStart: weekStart, weekDistance: 118_400, weekTrips: 9, weekRating: 67, weekFineRisk: 2_200_000,
    weekDeltaPercent: nil, dayDistances: [34_000, 22_000, 41_000, 21_400, 0, 0, 0],
    dayOverspeed: [false, false, true, false, false, false, false], topRiskPlace: "Юнусабад, Амира Темура", topRiskPasses: 4,
    usualWeekDistance: 165_000, monthDistance: 486_000, lifetimeDistance: 12_400_000, weekMovingDuration: 4.5 * 3600,
    lastTripDistance: 21_400, lastTripAt: thu1830.addingTimeInterval(-4000), updatedAt: thu1830.addingTimeInterval(-3600))

var snapClean: Snap { var s = snapFull; s.weekFineRisk = 0; s.weekRating = 92; s.topRiskPlace = nil; s.topRiskPasses = 0; s.dayOverspeed = .init(repeating: false, count: 7); return s }

let snapFew = Snap(weekStart: weekStart, weekDistance: 22_300, weekTrips: 2, weekRating: 81, weekFineRisk: 0,
    weekDeltaPercent: nil, dayDistances: [0, 0, 0, 22_300, 0, 0, 0], dayOverspeed: .init(repeating: false, count: 7),
    usualWeekDistance: 0, monthDistance: 22_300, lifetimeDistance: 22_300, weekMovingDuration: 3100,
    lastTripDistance: 12_100, lastTripAt: Date.now.addingTimeInterval(-7000), updatedAt: thu1830.addingTimeInterval(-3600))

let snapEmpty = Snap(weekStart: weekStart, updatedAt: thu1830.addingTimeInterval(-3600))
let snapNoAccess = Snap(hasAccess: false)
/// Понедельник новой недели у того, кто поездил всю прошлую: приложение открывали, поездок ещё нет.
let snapNewWeek = Snap(weekStart: weekStart, weekDistance: 0, weekTrips: 0, weekRating: -1, weekFineRisk: 0, weekDeltaPercent: nil,
    usualWeekDistance: 165_000, monthDistance: 486_000, lifetimeDistance: 12_400_000, lastTripDistance: 21_400,
    lastTripAt: thu1830.addingTimeInterval(-40*3600), updatedAt: thu1830.addingTimeInterval(-3600))
/// Приложение не открывали с прошлой недели: снимок чужой недели и старше суток.
var snapLastWeek: Snap { var s = snapFull; s.weekStart = weekStart.addingTimeInterval(-7*86400); s.updatedAt = thu1830.addingTimeInterval(-4*86400); return s }

func commute(_ now: Date, slot: Bool, jam: Bool, leaveBy: Bool = true) -> CommuteWidgetData {
    let day = cal.startOfDay(for: now)
    var work = CommuteWidgetData.Direction(usualSeconds: 2520, usualDepartureMinute: 500, bestStartMinute: 465, bestSeconds: 2160,
                                           leaveBy: leaveBy ? day.addingTimeInterval(29_400) : nil)
    var home = CommuteWidgetData.Direction(usualSeconds: 2340, usualDepartureMinute: 1110)
    if slot { let s = day.addingTimeInterval(8*3600); work.slots = [.init(start: s, seconds: 2640)]
              let h = day.addingTimeInterval(18.25*3600); home.slots = [.init(start: h, seconds: 2880)] }
    if jam { work.jam = .init(extraSeconds: 480, at: now.addingTimeInterval(-120)); home.jam = .init(extraSeconds: 600, at: now.addingTimeInterval(-120)) }
    return CommuteWidgetData(toWork: work, toHome: home, updatedAt: now.addingTimeInterval(-600))
}

typealias AS = CameraActivityAttributes.ContentState
let cameraFar = AS(nearestTitle: "Амира Темура, 14", nearestSymbol: "camera.fill", distanceMeters: 800, arrivesAt: thu1830.addingTimeInterval(45), since: thu1830.addingTimeInterval(-20),
    etaClock: thu1830.addingTimeInterval(1200), etaCaption: "Работа · 4,2 км", limitKmh: 60, alertLevel: 1)
var cameraNear: AS { var s = cameraFar; s.distanceMeters = 150; s.alertLevel = 3; s.arrivesAt = thu1830.addingTimeInterval(5); s.since = thu1830.addingTimeInterval(-40); return s }
var cameraFlash: AS { var s = cameraFar; s.reportFlash = true; s.reportUndo = false; return s }
var cameraUndo: AS { var s = cameraFar; s.reportFlash = true; s.reportUndo = true; return s }
var cameraFail: AS { var s = cameraFar; s.reportFlash = false; s.muted = true; return s }
let noCamera = AS(nearestTitle: nil, nearestSymbol: "checkmark.shield.fill", distanceMeters: nil, limitKmh: 40, alertLevel: 0)

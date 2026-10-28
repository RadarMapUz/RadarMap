//
//  PollSchedule.swift
//  RadarMap
//
//  Как часто спрашивать сервер о чужих отметках.
//
//  Была одна константа на всю поездку, и она раздавала запросы поровну между
//  теми, кому они нужны, и теми, кому нет. Телефон, стоящий в пробке, спрашивал
//  так же часто, как летящий по трассе, — хотя первому новость подождёт, а
//  второму через минуту будет уже поздно.
//
//  Участить получилось только после ETag: неизменившийся список приезжает
//  пустым ответом 304, без тела и без разбора JSON. Это и есть честный ответ на
//  «сделай доставку быстрее и энергоэффективнее» — не будить радио чаще
//  вслепую, а сделать каждое пробуждение почти бесплатным и потратить его там,
//  где оно меняет дело.
//
//  Пульт остаётся главнее расписания в одну сторону: если он СПЕЦИАЛЬНО
//  разредил опрос, это защита сервера от наплыва, и обходить её поездкой нельзя.
//
//  Чистая функция без Date и сети — покрыта PollScheduleTests. Ведёт такт
//  поездки всего планировщика сети (SyncPlan): отметки — ведущая служба.
//

import Foundation

nonisolated enum PollSchedule {

    static func interval(isTripActive: Bool,
                         speedKmh: Double,
                         thermal: PerformanceMode,
                         remoteBaseline: TimeInterval?) -> TimeInterval {
        let baseline = remoteBaseline ?? AppConfig.mobilePollInterval
        // Пульт разредил опрос сильнее нашего — слушаемся и не спорим.
        guard baseline <= AppConfig.mobilePollInterval else { return baseline }

        var interval = baseline
        if isTripActive {
            if speedKmh >= AppConfig.mobilePollFastKmh {
                interval = AppConfig.mobilePollTripFast
            } else if speedKmh <= AppConfig.mobilePollIdleKmh {
                interval = AppConfig.mobilePollTripIdle
            } else {
                interval = AppConfig.mobilePollTripCity
            }
        }
        // Телефон греется: радио — не то, на чём стоит настаивать. Оповещения
        // о камерах это не трогает, они уже в памяти.
        if thermal >= .reduced {
            interval *= AppConfig.mobilePollThermalFactor
        }
        return interval
    }
}

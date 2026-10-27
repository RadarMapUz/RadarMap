//
//  MissedAlertPrompt.swift
//  RadarMap
//
//  «Не предупредила» прямо на карточке «Поездка сохранена» (12.5).
//
//  Промолчать о настоящей камере — худшая ошибка приложения, а жалоба на неё
//  жила на четвёртом уровне: Итоги → поездка → проезд → кнопка внизу. Туда
//  доходит один водитель из ста. Между тем в момент стопа приложение само
//  знает, о каких камерах промолчало (`PassedCamera.silent`, 19.10), и
//  спросить можно одним касанием — с тем же текстом жалобы, что на экране
//  проезда (FeedbackService.reportMissedAlert): место, тип, скорость, лимит,
//  время, версия базы. Ничего нового о человеке.
//
//  Показываем только факт тишины, а не догадку: `silent == true` ставится,
//  когда за всю поездку не было ни одного оповещения об этой камере. nil —
//  оповещение было или запись старше поля: тогда строки нет вовсе.
//
//  Чистая логика — покрыта MissedAlertPromptTests.
//

import Foundation

nonisolated enum MissedAlertPrompt {

    /// Проезды, о которых приложение промолчало и о которых ещё не
    /// пожаловались, — по порядку проезда.
    static func candidates(passes: [PassedCamera], reported: Set<UUID> = []) -> [PassedCamera] {
        passes.filter { $0.silent == true && !reported.contains($0.id) }
            .sorted { $0.date < $1.date }
    }

    /// Заголовок строки: одна камера — с адресом в подписи, несколько — числом
    /// («Промолчала о 2 камерах»). Предложный падеж: «о 1 камере», «о 21
    /// камере», «о 2, 5, 11 камерах».
    static func title(count: Int) -> String {
        guard count > 1 else { return String(localized: "Промолчала о камере") }
        switch PluralRu.form(count) {
        case .one:        return String(format: String(localized: "Промолчала о %lld камере"), count)
        case .few, .many: return String(format: String(localized: "Промолчала о %lld камерах"), count)
        }
    }
}

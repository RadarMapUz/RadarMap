//
//  PassQuestionTimeout.swift
//  RadarMap
//
//  Сколько вопрос после проезда («Радар ещё стоял?», «Ещё перекрыто?») ждёт
//  ответа на экране телефона, прежде чем молча уйти.
//
//  Молчание ничего не отправляет, поэтому срок — вопрос не данных, а того,
//  успеет ли человек ответить. Глазу хватает двадцати секунд; с VoiceOver
//  путь до кнопки длиннее (объявление, пролистывание, двойное касание), и
//  срок дольше. Выше срока жизни самого вопроса (`mobileConfirmMaxAgeSeconds`)
//  он не поднимается ни при каких настройках: дольше это вопрос о прошлом.
//
//  Чистая логика, покрыта PassQuestionTimeoutTests.
//

import Foundation

nonisolated enum PassQuestionTimeout {

    /// Полный срок плашки на экране.
    static func seconds(voiceOver: Bool) -> TimeInterval {
        let wanted = voiceOver ? AppConfig.mobileQuestionVoiceOverSeconds : AppConfig.mobileQuestionSeconds
        return min(wanted, AppConfig.mobileConfirmMaxAgeSeconds)
    }

    /// Сколько ещё ждать, если плашка на экране уже `elapsed` секунд.
    ///
    /// Нужен на смене VoiceOver посреди вопроса: включили — вопрос доживает
    /// до длинного срока, считая от появления, а не начинает его заново;
    /// выключили — уходит по короткому (уже истёкшему — сразу).
    static func remaining(elapsed: TimeInterval, voiceOver: Bool) -> TimeInterval {
        max(0, seconds(voiceOver: voiceOver) - max(0, elapsed))
    }
}

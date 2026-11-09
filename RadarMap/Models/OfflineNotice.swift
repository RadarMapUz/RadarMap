//
//  OfflineNotice.swift
//  RadarMap
//
//  Что сказать на карте, когда пропала связь.
//
//  На новой карте отсутствие сети — это два очень разных состояния. Внутри
//  скачанной области карта рисуется с телефона, и человеку достаточно знать,
//  почему она может быть беднее обычной. Вне её карта серая — и тогда нужно
//  сказать главное: камеры предупреждают. Скачать без связи нечем, поэтому
//  кнопки «Скачать» здесь нет; предложение придёт, когда связь вернётся.
//
//  На карте Apple и на прежнем стиле движка скачанные файлы ничего не дают —
//  там остаётся общая плашка «нет сети».
//
//  Чистое решение — покрыто OfflineNoticeTests.
//

nonisolated enum OfflineNotice: Equatable {
    /// Карта не наша (или прежний стиль): общая плашка «нет сети».
    case general
    /// Новая карта, машина внутри скачанной области: карта с телефона.
    case downloadedRegion
    /// Новая карта, области на телефоне нет: карта не грузится.
    case noMap
    /// Связь есть, сервер карты не отвечает (S22): «нет связи» было бы
    /// неправдой. С областью на телефоне — карта с неё.
    case serverDown
    case serverDownRegion

    /// nil — связь есть и сервер карты на месте, плашка не нужна.
    static func resolve(online: Bool, modernMap: Bool, hasRegionFiles: Bool,
                        serverDown: Bool = false) -> OfflineNotice? {
        if online {
            guard serverDown else { return nil }
            return modernMap && hasRegionFiles ? .serverDownRegion : .serverDown
        }
        guard modernMap else { return .general }
        return hasRegionFiles ? .downloadedRegion : .noMap
    }
}

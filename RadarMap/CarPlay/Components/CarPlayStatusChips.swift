//
//  CarPlayStatusChips.swift
//  RadarMap
//
//  Честные плашки состояния на экране машины.
//
//  До этого CarPlay сообщал ровно об одном состоянии — о жаре. Ни «нет сети»,
//  ни объявления пульта в машине не показывались вообще: карта становилась
//  серой, приложение молчало, и водителю оставалось решать, что сломалось.
//  На телефоне такие плашки есть с самого начала, и разница между
//  «приложение сломалось» и «карта не грузится, но я предупреждаю» стоит
//  ровно одной строки текста.
//
//  Порядок жёсткий и осмысленный: сверху то, что отнимает у водителя защиту
//  (нет разрешения), ниже то, что портит картинку (нет сети), ниже то, что
//  экономит ресурс (жара), и в конце — слово владельца (объявление пульта).
//  Больше двух плашек разом не показываем: экран машины — не лента.
//

import SwiftUI

struct CarPlayStatusChips: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Только две верхние по важности: третья уже не читается за рулём.
        let shown = chips.prefix(2)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { chip in
                    CarPlayStatusChip(chip: chip)
                }
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .motionAnimation(.easeOut(duration: 0.3), value: shown.map(\.id))
        }
    }

    private var chips: [CarPlayChip] {
        var result: [CarPlayChip] = []
        // Без разрешения экран машины мёртв целиком — это важнее всего
        // остального вместе взятого.
        if !env.location.isAuthorized {
            // Коротко и действием: за рулём читают глиф и два-три слова,
            // длинная фраза на узком экране обрезалась на самом важном.
            result.append(CarPlayChip(id: "auth", symbol: Icon.noLocationAccess,
                                      tint: Theme.danger,
                                      text: String(localized: "Разрешите геопозицию на телефоне")))
        } else if !env.location.isAlwaysAuthorized {
            // «При использовании»: наш экран жив, но стоит открыть в машине
            // другое приложение при заблокированном телефоне — фиксы встанут,
            // и голос замолчит. Молчать о такой деградации нельзя.
            result.append(CarPlayChip(id: "whenInUse", symbol: "location.circle",
                                      tint: Theme.warning,
                                      text: String(localized: "Дайте доступ «Всегда» на телефоне")))
        }
        // Тишина включается кнопкой в баре рядом с «Поездкой»: промах слепого
        // тапа не должен глушить камеры незаметно. Выше сети и жары — это
        // единственное состояние, при котором водитель не услышит камеру.
        if !env.settings.soundEnabled && env.settings.voiceMode == .off {
            result.append(CarPlayChip(id: "muted", symbol: "speaker.slash.fill",
                                      tint: Theme.warning,
                                      text: String(localized: "Без звука")))
        }
        // Тайлы карты требуют сети, база камер — нет. Сказать об этом обязаны:
        // серая карта без объяснения читается как сломанное приложение.
        if !env.network.isOnline {
            result.append(CarPlayChip(id: "offline", symbol: "wifi.slash",
                                      tint: Theme.warning,
                                      text: String(localized: "Нет сети — камеры работают")))
        } else if env.network.isTileServerDown {
            // Связь есть, сервер карты лёг (S22): «нет сети» было бы неправдой.
            result.append(CarPlayChip(id: "offline", symbol: "server.rack",
                                      tint: Theme.warning,
                                      text: String(localized: "Карта не отвечает — камеры работают")))
        }
        // Жара: бюджеты уже урезаны (маркеры карты, сеть схемы) — но молча.
        if env.thermal.mode != .full {
            result.append(CarPlayChip(id: "thermal", symbol: "thermometer.sun.fill",
                                      tint: Theme.warning,
                                      text: String(localized: "Жарко — экономлю экран")))
        }
        // Слово владельца: то же объявление, что видит телефон. В машине —
        // только заголовок: тело сообщения за рулём всё равно не прочитают,
        // а обрезанная фраза хуже короткой.
        if let banner = env.config.banner {
            result.append(CarPlayChip(id: "banner", symbol: "megaphone.fill",
                                      tint: Theme.accent, text: banner.title))
        }
        return result
    }
}

/// Одна плашка. Значение — чтобы список можно было сравнивать и анимировать.
struct CarPlayChip: Identifiable, Equatable {
    let id: String
    let symbol: String
    let tint: Color
    let text: String
}

/// Внешний вид плашки — один на все состояния: за рулём разный вид у
/// однотипных сообщений заставляет читать каждое заново.
struct CarPlayStatusChip: View {
    let chip: CarPlayChip

    var body: some View {
        // Глиф на пункт крупнее и жирнее текста: так он читается пиктограммой,
        // а не первой буквой фразы.
        Label {
            Text(chip.text)
                .font(.rounded(14, .semibold))
        } icon: {
            Image(systemName: chip.symbol)
                .font(.rounded(15, .bold))
        }
        .foregroundStyle(chip.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(chip.tint.opacity(0.35), lineWidth: 1))
    }
}

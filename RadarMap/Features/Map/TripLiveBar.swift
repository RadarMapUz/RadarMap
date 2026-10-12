//
//  TripLiveBar.swift
//  RadarMap
//
//  Нижняя панель поездки — одна строка, как у навигаторов:
//  `19:35 / 4 мин · 3.3 км   [камера 240 м]   [Стоп] [Радар]`.
//
//  Снимок с дороги: «19:3 / 5» в две строки, «2 / 3 / 3 / м» столбиком по
//  буквам, батарея посередине. Тексты не были ни однострочными, ни
//  жёсткими, а капсула камеры и заряд делили с ними ширину — на узком экране
//  SwiftUI сжимал цифры и переносил их по буквам
//  (docs/plan_drive_ux_2026-10-07.md, п. 3).
//
//  Теперь цифры не сжимаются никогда: их размер — свой (fixedSize), а при
//  нехватке места уходит то, без чего можно, — сначала капсула камеры (до
//  камеры на подходе всё равно есть чип под манёвром), и лишь в крайнем
//  случае на огромном системном шрифте цифры уменьшаются целиком, но не
//  ломаются. Кнопки справа не участвуют в торге: по ним бьют вслепую, и
//  размер — часть того, как их находят.
//
//  Заряда здесь больше нет: он на приборке и в итогах поездки, а в панели
//  занимал середину и спорил с прибытием за взгляд.
//

import SwiftUI

struct TripLiveBar: View {
    @Environment(AppEnvironment.self) private var env
    let onShowCameras: () -> Void
    let onStop: () -> Void

    /// Ширина гибкой части; с неё решается, влезает ли капсула камеры.
    @State private var barWidth: CGFloat = 0
    /// Сводка («19:35 · 12 мин · 4,2 км») и капсула («📷 320 м») рядом —
    /// от ~200 pt; у́же — только сводка (SE в крупном шрифте).
    static let cameraCapsuleMinWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 10) {
            // Гибкая часть — сведения о пути. Раньше здесь стоял ViewThatFits
            // с тремя вариантами: он раскладывал все три на КАЖДОМ тике GPS
            // (аудит 11.10, п. 8). Теперь решение по ширине панели, которая
            // меняется только со сменой экрана: капсула камеры показывается,
            // когда места хватает, а сводка в крайнем случае ужимается одной
            // строкой — никаких «19:3 / 5».
            HStack(spacing: 10) {
                summary
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                if barWidth >= Self.cameraCapsuleMinWidth {
                    cameraCapsule
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            // «Радар!» — у самого края, «Стоп» — перед ней. Было наоборот, и
            // взведённый «Стоп» («Точно?», 44 → ~104 pt) толкал «Радар!» на
            // 60 pt влево и сам ложился на её прежнее место: три секунды
            // слепой тап по «Радар!» подтверждал конец поездки — ровно тот
            // промах, от которого защищает двойное касание. Теперь «Радар!»
            // не двигается никогда: «Стоп» растёт влево, в сторону сводки,
            // а его правая часть остаётся там, где был первый тап.
            // «Радар!» крупнее соседки — второй признак, кроме цвета, который
            // читается боковым зрением.
            StopTripButton(action: onStop)
                .padding(.trailing, 4)
            ReportRadarButton()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Сплошная панель, как у кластера скорости и чипа камеры: под ней
        // живая карта, и материал заставлял систему заново размывать её на
        // каждом кадре всю поездку (аудит 11.10).
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Сведения о пути

    /// С маршрутом — время прибытия крупно и остаток мелко; без — таймер
    /// крупно и «км · камеры» мелко. Одна вёрстка на оба случая: глаз ищет
    /// крупную зелёную цифру на одном и том же месте.
    @ViewBuilder
    private var summary: some View {
        let route = env.route
        VStack(alignment: .leading, spacing: 0) {
            if route.isActive {
                // Прибытие: как в настоящих навигаторах — время на часах + остаток.
                Text(route.arrivalDate, style: .time)
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.success)
                    .contentTransition(.numericText())
                Text(verbatim: "\(Formatting.duration(route.remainingTime)) · \(Formatting.distance(route.remainingDistance))")
                    .font(.rounded(12, .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .liveNumber()
            } else {
                // Свободная поездка без маршрута: таймер + путь + камеры.
                if let started = env.trip.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.rounded(22, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.success)
                }
                // Эмодзи-камера рендерилась чёрно-белым глифом и выбивалась
                // из всего интерфейса — здесь тот же SF Symbol, что везде.
                HStack(spacing: 4) {
                    Text(Formatting.distance(env.trip.distanceMeters))
                        .liveNumber()
                    Text(verbatim: "·")
                    Image(systemName: "camera.fill")
                        .font(.rounded(10, .semibold))
                    Text(verbatim: "\(env.trip.camerasPassed)")
                        .contentTransition(.numericText())
                }
                .font(.rounded(12, .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(Formatting.distance(env.trip.distanceMeters)))
                .accessibilityValue(Text(verbatim: "\(env.trip.camerasPassed) ") + Text("камер пройдено"))
            }
        }
        .lineLimit(1)
    }

    /// Следующая камера по маршруту. Только с маршрутом: без него камера
    /// впереди не определена, а ближайшая по прямой есть в HUD сверху.
    @ViewBuilder
    private var cameraCapsule: some View {
        let route = env.route
        if route.isActive, env.settings.showNextCamera, let next = route.nextCamera {
            Button(action: onShowCameras) {
                HStack(spacing: 5) {
                    Image(systemName: next.camera.kind.symbolName)
                        .font(.rounded(11, .bold))
                        .foregroundStyle(next.camera.kind.glyphTint)
                        .frame(width: 24, height: 24)
                        .background(next.camera.kind.tint.gradient, in: Circle())
                    Text(Formatting.distance(route.nextCameraDistance))
                        .font(.rounded(13, .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .liveNumber()
                }
                .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .fixedSize()
                // Капсула ~34 pt — мишень растёт до 44, рисунок нет.
                .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Камеры на маршруте"))
            .accessibilityValue(Text(Formatting.distance(route.nextCameraDistance)))
        }
    }
}

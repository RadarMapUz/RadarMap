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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Вопрос на ходу (этап 45, вариант B) — панель на его время становится им.
    let map: MapState
    let onShowCameras: () -> Void
    let onStop: () -> Void
    /// «Опаздываю — предупредить?» → лист «Поделиться» у экрана карты.
    let onLateShare: (String) -> Void

    /// Ширина гибкой части; с неё решается, влезает ли капсула камеры.
    @State private var barWidth: CGFloat = 0
    /// Сводка («19:35 · 12 мин · 4,2 км») и капсула («📷 320 м») рядом —
    /// от ~200 pt; у́же — только сводка (SE в крупном шрифте).
    static let cameraCapsuleMinWidth: CGFloat = 200

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        Group {
            // Вопрос на ходу — вместо содержимого панели, а не новым слоем над
            // ней: «Стоп» на это время убран (промах по нему невозможен),
            // «Отметить» — на своём месте у края, прибытие — в углу.
            if let shown = map.roadPrompt, Self.morphs(shown.kind),
               let model = RoadPromptContent.model(for: shown, env: env, map: map, voiceOver: voiceOver,
                                                   onLateShare: onLateShare) {
                RoadPromptCard(model: model, eta: promptETA) { ReportButton() }
                    .id(shown.id)
                    .transition(.opacity)
            } else {
                tripRow
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .transition(.opacity)
            }
        }
        .motionAnimation(Motion.standard, value: map.roadPrompt)
        // Сплошная панель, как у кластера скорости и чипа камеры: под ней
        // живая карта, и материал заставлял систему заново размывать её на
        // каждом кадре всю поездку (аудит 11.10).
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Становится ли панель этим вопросом. «Карта по пути» — нет: срока у неё
    /// нет, и «Стоп» не должен прятаться, пока не ответят или не тронутся.
    static func morphs(_ kind: RoadPromptPolicy.Kind) -> Bool { kind != .corridor }

    /// Прибытие в углу вопроса: по маршруту или по своим прошлым поездкам.
    private var promptETA: String? {
        if env.route.isActive { return env.route.arrivalText }
        return env.commuteLive.display.map { Formatting.clock($0.arrival) }
    }

    private var tripRow: some View {
        HStack(spacing: 10) {
            // Гибкая часть — сведения о пути. Раньше здесь стоял ViewThatFits
            // с тремя вариантами: он раскладывал все три на КАЖДОМ тике GPS
            // (аудит 11.10, п. 8). Теперь решение по ширине панели, которая
            // меняется только со сменой экрана: капсула камеры показывается,
            // когда места хватает, а сводка в крайнем случае ужимается одной
            // строкой — никаких «19:3 / 5».
            HStack(spacing: 10) {
                if env.route.isActive {
                    // С маршрутом — как у Яндекса (29.G): осталось · прибытие ·
                    // минуты и под ними полоса хода с пробками и камерами.
                    // Камеры маршрута — точки на полосе; капсула «📷 320 м»
                    // рядом не помещалась бы и повторяла бы чип у манёвра.
                    routeSummary
                } else {
                    summary
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    if barWidth >= Self.cameraCapsuleMinWidth {
                        cameraCapsule
                    }
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
            ReportButton()
        }
    }

    // MARK: - Сведения о пути

    /// Маршрут: три числа одной строкой и полоса хода под ними. Цифры не
    /// переносятся никогда — в крайнем случае (SE, крупный шрифт) строка
    /// ужимается целиком; прибытие — крупное на том же месте, что и без
    /// маршрута.
    private var routeSummary: some View {
        let route = env.route
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Formatting.distance(route.remainingDistance))
                    .font(.numeral(19, .bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: route.arrivalText)
                    .font(.numeral(21, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .fixedSize()
                Text(Formatting.duration(route.remainingTime))
                    .font(.numeral(19, .bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityElement(children: .combine)
            Button(action: onShowCameras) {
                // Мишень — 44 pt по высоте (правило 22), а строка остаётся
                // в 14 pt: поле касания растёт, панель — нет.
                RouteProgressStripGate()
                    .padding(.horizontal, AppConfig.routeStripMeSize / 2)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                    .padding(.vertical, -15)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Камеры на маршруте"))
        }
        .frame(maxWidth: .infinity)
    }

    /// С маршрутом — время прибытия крупно и остаток мелко; без — таймер
    /// крупно и «км · камеры» мелко. Одна вёрстка на оба случая: глаз ищет
    /// крупную цифру на одном и том же месте.
    ///
    /// Цвет цифры — `textPrimary`, не `success` (33H3, 28.10): зелёный в
    /// приложении значит «в лимите, чисто», а время поездки и прибытия —
    /// нейтральный факт. Зелёный таймер читался оценкой, которой нет.
    @ViewBuilder
    private var summary: some View {
        let route = env.route
        VStack(alignment: .leading, spacing: 0) {
            if route.isActive {
                // Прибытие: как в настоящих навигаторах — время на часах + остаток.
                Text(verbatim: route.arrivalText)
                    .font(.numeral(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(verbatim: "\(Formatting.duration(route.remainingTime)) · \(Formatting.distance(route.remainingDistance))")
                    .font(.rounded(12, .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .liveNumber()
            } else if let ghost = env.commuteLive.display {
                // Дорога на работу без маршрута (этап 8): прибытие по своим
                // прошлым поездкам. Меняется раз в минуту — numericText можно.
                Text(verbatim: Formatting.clock(ghost.arrival))
                    .font(.numeral(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(verbatim: GhostText.caption(ghost))
                    .font(.rounded(12, .medium).monospacedDigit())
                    .foregroundStyle(GhostText.tint(ghost))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                // Свободная поездка без маршрута: таймер + путь + камеры.
                if let started = env.trip.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.numeral(22, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                // Эмодзи-камера рендерилась чёрно-белым глифом и выбивалась
                // из всего интерфейса — здесь тот же SF Symbol, что везде.
                HStack(spacing: 4) {
                    Text(Formatting.distance(env.trip.distanceMeters))
                        .liveNumber()
                    Text(verbatim: "·")
                    SymbolIcon(Icon.cameras, size: 10)
                    Text(verbatim: "\(env.trip.camerasPassed)")
                        .contentTransition(.numericText())
                }
                .font(.rounded(12, .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(Formatting.distance(env.trip.distanceMeters)))
                .accessibilityValue(Text("Пройдено камер: \(env.trip.camerasPassed)"))
            }
        }
        .lineLimit(1)
    }

    /// Следующая камера по маршруту. Только с маршрутом: без него камера
    /// впереди не определена, а ближайшая по прямой есть в HUD сверху.
    @ViewBuilder
    private var cameraCapsule: some View {
        let route = env.route
        let location = env.location
        let chipShown = TripScreenLayout.showsCameraChip(
            distance: location.displayNearestCamera == nil ? nil : location.displayDistanceToNearest,
            isAlerting: location.alertLevel >= 1, isSignalStale: location.isSignalStale)
        if route.isActive, env.settings.showNextCamera, let next = route.nextCamera,
           TripScreenLayout.showsCameraCapsule(capsuleCameraID: next.camera.id,
                                               chipCameraID: location.displayNearestCamera?.id,
                                               chipShown: chipShown,
                                               isSignalStale: location.isSignalStale) {
            Button(action: onShowCameras) {
                HStack(spacing: 5) {
                    CameraIcon(kind: next.camera.kind, side: 24)
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

    // Слова призрака — GhostText (одни на панели, в CarPlay и на плашке).
}

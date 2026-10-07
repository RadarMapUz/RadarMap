//
//  TripLiveBar.swift
//  RadarMap
//
//  Нижняя панель поездки — одна строка, как у навигаторов:
//  `19:35 / 4 мин · 3.3 км   [камера 240 м]   [Радар] [Стоп]`.
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

    var body: some View {
        HStack(spacing: 10) {
            // Гибкая часть — сведения о пути. ViewThatFits выбирает первый
            // вариант, который влезает целиком в своём настоящем размере.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    summary.fixedSize()
                    cameraCapsule
                }
                summary.fixedSize()
                // Крайний случай (SE + самый крупный шрифт): уменьшить, но
                // одной строкой — никаких «19:3 / 5».
                summary.minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // «Радар!» слева от «стоп» — в поездке это самая частая кнопка
            // после самой остановки, и до неё палец должен доходить не глядя.
            // Она же крупнее соседки: промах между ними стоил поездки, и
            // разница в размере — второй признак, кроме цвета, который читается
            // боковым зрением.
            ReportRadarButton()
                .padding(.trailing, 4)
            StopTripButton(action: onStop)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
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
                    .contentTransition(.numericText())
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
                        .contentTransition(.numericText())
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
                        .contentTransition(.numericText())
                }
                .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Камеры на маршруте"))
            .accessibilityValue(Text(Formatting.distance(route.nextCameraDistance)))
        }
    }
}

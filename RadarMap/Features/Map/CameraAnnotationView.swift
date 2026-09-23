//
//  CameraAnnotationView.swift
//  RadarMap
//
//  Маркер камеры на карте.
//
//  У маркера два измерения, и путать их нельзя: ТИП камеры кодируется глифом и
//  приглушённым цветом семейства Types, а ВАЖНОСТЬ прямо сейчас (CameraTier) —
//  размером и плотностью. Раньше было только первое, и полсотни точек в кадре
//  читались как сыпь: камера в 400 метрах по курсу выглядела так же, как камера
//  в трёх километрах за спиной.
//
//  Сектор направления рисуется только там, где направление ДОКАЗАНО
//  (`allowsDirectionGate`). Половина базы доказать его не может, и пририсовать
//  таким камерам клин значило бы соврать: они вполне могут снимать обе стороны.
//

import SwiftUI

struct CameraAnnotationView: View {
    let camera: Camera
    var selected: Bool = false
    /// Средний зум: маленькая точка вместо полного пина — экран не забит кружками.
    var compact: Bool = false
    /// Лимит дороги у камеры: на близком зуме маркер = мини-знак «60» —
    /// сколько можно, видно с одного взгляда, без тапа в карточку.
    var limit: Int? = nil
    /// Важность прямо сейчас: цель / рядом / фон.
    var tier: CameraTier = .near
    /// Поворот карты (0 — север вверху). Контент Annotation экранно-выровнен
    /// и с картой не вращается — клин компенсирует поворот сам; nil — угол
    /// неизвестен (compass-follow), клин честно прячется.
    var mapHeading: Double? = 0

    /// Фоновые камеры не тают в ноль: пропавшая камера — худшая ошибка карты,
    /// чем лишняя. Они просто перестают спорить за взгляд.
    private var dimming: Double {
        tier == .background ? AppConfig.mapBackgroundCameraOpacity : 1
    }

    /// Отметка водителей на испытательном сроке: никто независимый её ещё не
    /// подтвердил. Рисуем призраком со знаком вопроса — слух не должен
    /// выглядеть на карте так же уверенно, как проверенная точка.
    private var isGhost: Bool { camera.isUnconfirmedMobile }

    /// Силуэт маркера. Тренога отличается от стационарного радара ФОРМОЙ, а не
    /// одним цветом: цвет у них общий (одна семья «радар»), а за рулём боковым
    /// зрением читается именно силуэт. Круг — всё стационарное, скруглённый
    /// квадрат — тренога: её ставят на час, и путать её с постоянной точкой
    /// нельзя ни на карте, ни в голове.
    private var pinShape: AnyShape {
        camera.kind == .tripod
            ? AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            : AnyShape(Circle())
    }

    /// «Своя» камера: проезжаем регулярно и спокойно, голос о ней молчит.
    /// Молчание обязано быть видимым — иначе оно читается как поломка
    /// («камера на карте есть, а приложение молчит»). Спокойная галочка на
    /// плече отвечает на этот вопрос до того, как он возникнет.
    var isFamiliar: Bool = false

    var body: some View {
        Group {
            if compact && !selected {
                dot
            } else if let limit, !selected {
                limitPin(limit)
            } else {
                fullPin
            }
        }
        .opacity(dimming)
    }

    /// Точка среднего зума. Фоновая мельче «своей» — иерархия читается даже
    /// там, где на весь маркер приходится десяток пикселей.
    private var dot: some View {
        let size: CGFloat = tier == .background ? 8 : 12
        return pinShape
            .fill(camera.kind.tint.opacity(isGhost ? 0.45 : 1))
            .frame(width: size, height: size)
            .overlay(pinShape.stroke(.white.opacity(0.75), lineWidth: 1))
            // Тап-мишень больше самой точки, и не на глаз: 44 pt — размер
            // подушечки пальца. По камере тыкают НА ХОДУ, из держателя, и
            // тридцать точек здесь означали промах через раз — по объекту,
            // ради которого приложение и существует.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    /// Мини-знак ограничения: белый круг, красная кайма, число. Цветная точка
    /// снизу сохраняет тип камеры (радар/камера/интеллектуал).
    private func limitPin(_ limit: Int) -> some View {
        ZStack {
            // Клин крупнее знака и лежит под ним: внутри рамки знака он был бы
            // перекрыт им целиком и не читался вовсе.
            directionCone(radius: 25).offset(y: -3)
            ZStack(alignment: .bottom) {
                ZStack {
                    Circle().fill(.white)
                    // Тот же красный, что у SpeedLimitSign: знак уже рисуется
                    // в HUD, деталке и CarPlay — кайма не должна отличаться.
                    Circle().strokeBorder(Color(red: 0.85, green: 0.05, blue: 0.1), lineWidth: 4.5)
                    Text("\(limit)")
                        .font(.system(size: limit >= 100 ? 10 : 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 30, height: 30)

                Circle()
                    .fill(camera.kind.tint)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(y: 3)
            }
            .frame(width: 34, height: 36)
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
    }

    private var fullPin: some View {
        ZStack {
            // Цель подсвечена ореолом: на экране должен быть один фокус.
            if selected || tier == .target {
                Circle()
                    .fill(camera.kind.tint.opacity(selected ? 0.25 : 0.18))
                    .frame(width: selected ? 54 : 46, height: selected ? 54 : 46)
            }
            directionCone(radius: selected ? 30 : 24)
            pinShape
                .fill(camera.kind.tint.opacity(isGhost ? 0.5 : 1).gradient)
                .frame(width: selected ? 38 : 28, height: selected ? 38 : 28)
                .overlay(pinShape.stroke(.white.opacity(0.9),
                                         style: StrokeStyle(lineWidth: 2,
                                                            dash: isGhost ? [3, 3] : [])))
                // Тень только у выбранного маркера: shadow = offscreen-проход рендера,
                // на ~220 аннотациях при панорамировании это заметно.
                .shadow(color: camera.kind.tint.opacity(selected ? 0.7 : 0), radius: selected ? 9 : 0)

            Image(systemName: camera.kind.symbolName)
                .font(.rounded(selected ? 16 : 13, .bold))
                .foregroundStyle(.white.opacity(isGhost ? 0.8 : 1))

            if camera.isApproximate {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .background(Circle().fill(.black).frame(width: 10, height: 10))
                    .offset(x: 13, y: -13)
            } else if isGhost {
                // «?» на плече — та же позиция, что у бейджа неточной камеры:
                // у краудсорса needsReview не бывает, слот всегда свободен.
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .background(Circle().fill(.black).frame(width: 10, height: 10))
                    .offset(x: 13, y: -13)
            } else if isFamiliar {
                // «Своя»: галочка вместо голоса. Тот же слот на плече —
                // у своей камеры не бывает ни needsReview, ни призрака.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.success)
                    .background(Circle().fill(.black).frame(width: 10, height: 10))
                    .offset(x: 13, y: -13)
            }
        }
        .motionAnimation(.spring(duration: 0.25), value: selected)
    }

    /// Клин по направлению съёмки. Направление камеры — свойство дороги, а
    /// контент Annotation экранно-выровнен, поэтому известный поворот карты
    /// вычитаем, а при неизвестном клин спрятан (см. mapHeading).
    @ViewBuilder private func directionCone(radius: CGFloat) -> some View {
        if let heading = camera.markerDirection, let mapHeading {
            DirectionCone(spread: AppConfig.mapDirectionConeDegrees)
                .fill(camera.kind.tint.opacity(0.45))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(Double(heading) - mapHeading))
                .allowsHitTesting(false)
        }
    }
}

/// Сектор «камера смотрит туда»: клин, раскрытый вверх от центра.
/// Поворачивается `rotationEffect` — 0° означает «на север».
private struct DirectionCone: Shape {
    /// Полный угол раскрытия, градусы.
    let spread: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // SwiftUI отсчитывает углы от оси X по часовой стрелке — «вверх» это −90°.
        let start = Angle.degrees(-90 - spread / 2)
        let end = Angle.degrees(-90 + spread / 2)
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end,
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Кластер на широком зуме: кружок с числом камер, тап — приближение.
struct ClusterAnnotationView: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.rounded(count > 99 ? 12 : 14, .bold))
            .foregroundStyle(Theme.background)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.accent.gradient))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
    }

    private var size: CGFloat {
        count > 99 ? 46 : count > 19 ? 40 : 34
    }
}

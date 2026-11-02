//
//  ApproachAlertView.swift
//  RadarMap
//
//  Полноэкранное предупреждение при приближении к камере — крупно, читается
//  боковым зрением.
//
//  Переделано 13.10 под палитру А. До этого экран был полупрозрачным
//  градиентом поверх карты: днём на светлой карте белый текст терялся в
//  розовом, подписи «прямо» и «67 км/ч» рисовались белым по белой капсуле,
//  а сквозь экран просвечивали кнопки и панели — самый важный экран
//  приложения читался хуже всех (снимок 12.10).
//
//  Теперь экран НЕПРОЗРАЧНЫЙ и всегда тёмный (`colorScheme` закреплён, как у
//  карточек «Поделиться»): графит, сверху — полоса цвета типа камеры, чтобы
//  тип читался раньше цифры. Порядок чтения сверху вниз: тип и адрес →
//  расстояние (главное) → полоса приближения → направление и скорость со
//  знаком лимита → кнопки. Никаких материалов и теней на составных вью:
//  карта под экраном продолжает ехать (аудит 11.10).
//
//  Внизу — две кнопки: «без звука» и «Радар!», под ними «Скрыть» (до
//  следующей камеры). До 19.10 экран скрывало ЛЮБОЕ касание мимо кнопок —
//  телефон в держателе задевают, поправляя его, и предупреждение пропадало
//  ровно у камеры (аудит 10.10, «осталось»).
//
//  В навигации экран — нижняя карточка, а не весь экран (`Layout`): на
//  перекрёстке с камерой полноэкранное окно закрывало манёвр, то есть
//  ровно тот момент, когда водителю нужнее всего, куда поворачивать.
//
//  При выборе маршрута — верхняя карточка (28.K, 27.10). Камера в паре
//  десятков метров от старта, маршрут строится несколько секунд: окно
//  вставало раньше маршрута и, когда тот приходил, накрывало панель с
//  вариантами и «Поехали» — водитель стоял перед тёмным экраном и не мог
//  уехать. Предупреждение при этом то же самое: звук, голос и вибрация
//  отработали в LocationService до всякой вёрстки, окно показывается
//  сразу, ничего не ждёт и не прячется — меняется только его место:
//  сверху, а панель маршрута внизу остаётся видна и нажимается.
//

import SwiftUI

struct ApproachAlertView: View {
    /// Как показать предупреждение. Чистое решение — ApproachAlertLayoutTests.
    enum Layout: Equatable {
        /// Без маршрута: весь экран, читается боковым зрением.
        case fullScreen
        /// В навигации: карточка снизу, баннер манёвра сверху остаётся виден.
        case bottomCard
        /// Выбор маршрута (маршрут строится или построен, поездки нет):
        /// карточка сверху — снизу панель вариантов и «Поехали» (28.K).
        case topCard

        /// `choosingRoute` — поездки нет, а маршрут строится или построен.
        /// Ведение старше выбора: в поездке манёвр сверху, карточка снизу.
        static func choose(navigating: Bool, choosingRoute: Bool = false) -> Layout {
            if navigating { return .bottomCard }
            return choosingRoute ? .topCard : .fullScreen
        }

        /// Раскладка по живому состоянию — одна на окно и на карту под ним
        /// (частота кадров «накрыто» обязана знать то же, что видит водитель).
        static func current(isTripActive: Bool, hasRoute: Bool, isBuildingRoute: Bool) -> Layout {
            choose(navigating: MapMode.current(isTripActive: isTripActive, hasRoute: hasRoute).showsManeuver,
                   choosingRoute: !isTripActive && (hasRoute || isBuildingRoute))
        }

        /// Закрывает ли окно карту целиком: только полный экран. Под
        /// карточками карта видна и обязана рисоваться в полную силу.
        var coversMap: Bool { self == .fullScreen }
    }

    @Environment(AppEnvironment.self) private var env
    let camera: Camera
    let distance: Double
    let speedKmh: Double
    let relativeBearing: Double?
    let alertRadius: Double
    var layout: Layout = .fullScreen
    /// Верхняя кромка нижней карточки в пунктах окна (nil — карточки нет):
    /// карта поднимает «я» и камеру над ней (MapFrameState).
    var onCardEdge: (CGFloat?) -> Void = { _ in }
    /// Нижняя кромка верхней карточки (nil — её нет): карта опускает «я» и
    /// начало маршрута под неё.
    var onTopCardEdge: (CGFloat?) -> Void = { _ in }
    let onDismiss: () -> Void

    @State private var pulse = false

    private var tint: Color { camera.kind.tint }
    /// 0…1 — насколько близко (для полосы приближения).
    private var proximity: Double {
        max(0, min(1, 1 - distance / max(alertRadius, 1)))
    }
    private var isOverspeeding: Bool { env.speedLimits.isOverspeeding }

    var body: some View {
        switch layout {
        case .fullScreen: fullScreen
        case .bottomCard: bottomCard
        case .topCard:    topCard
        }
    }

    /// Верхняя карточка выбора маршрута: тип и адрес, расстояние, полоса
    /// приближения и две кнопки — «без звука» и «Скрыть». Скорость и
    /// «Радар!» не нужны: стоим у старта, а уехать — это «Поехали» внизу.
    private var topCard: some View {
        VStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    CameraIcon(kind: camera.kind, side: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(camera.kind.displayName)
                            .font(.rounded(16, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        if !camera.location.isEmpty {
                            Text(camera.location)
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(distance.rounded()))")
                            .font(.numeralFree(38, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .liveNumber()
                        Text("м").font(.rounded(18, .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                proximityBar
                HStack(spacing: 10) {
                    compactMuteButton
                    hideButton
                        .background(Theme.quietFill,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background {
                // Полоса цвета типа сверху — тот же сигнал, что у полного экрана.
                ZStack(alignment: .top) {
                    Theme.alertSurface
                    tint.frame(height: 5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { onTopCardEdge($0) }
            .onDisappear { onTopCardEdge(nil) }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            Spacer()
        }
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// «Без звука» в строку высотой 44 — для верхней карточки.
    private var compactMuteButton: some View {
        let muted = env.settings.isMuted
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            env.settings.setMuted(!muted)
            if !muted { env.alerts.hush() }
        } label: {
            Label(muted ? "Включить звук" : "Без звука",
                  systemImage: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                .background(Theme.quietFill,
                            in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private var fullScreen: some View {
        ZStack {
            Theme.alertSurface.ignoresSafeArea()
            // Полоса цвета типа сверху — тип виден боковым зрением.
            VStack {
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 12)
                Spacer(minLength: 12)
                distanceBlock
                detailsRow
                    .padding(.top, 36)
                Spacer(minLength: 12)
                // Место под кнопки внизу (они лежат отдельным слоем):
                // 56 кнопки + 10 + 44 «Скрыть» + 4 — с запасом.
                Color.clear.frame(height: 122)
            }
            .padding(.horizontal, 24)
            // VoiceOver: сведения — одна фраза; скрыть — только кнопкой
            // «Скрыть», как и касанием (случайная активация не убирает окно).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            VStack(spacing: 10) {
                Spacer()
                HStack(spacing: 12) {
                    muteButton
                    ReportButton(source: .phoneAlert)
                }
                .padding(.horizontal, 24)
                hideButton
                    .padding(.bottom, 4)
            }
        }
        .environment(\.colorScheme, .dark)
        // Касание мимо кнопок не уходит в карту под экраном и ничего не
        // скрывает: скрыть — только кнопкой (см. шапку файла).
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear { pulse = true }
        .transition(.opacity.combined(with: .scale(scale: 1.03)))
    }

    /// Нижняя карточка навигации: тип и адрес строкой, расстояние справа,
    /// полоса приближения, направление и скорость, кнопки. Сверху карта и
    /// баннер манёвра остаются видны.
    private var bottomCard: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    CameraIcon(kind: camera.kind, side: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        // Тип — целиком, хоть в две строки: на SE «Стационарная
                        // ка…» обрезалось многоточием (снимок этапа 31), а тип
                        // камеры — то, ради чего водитель смотрит на карточку.
                        // Обрезается адрес, не тип.
                        Text(camera.kind.displayName)
                            .font(.rounded(17, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        if !camera.location.isEmpty {
                            Text(camera.location)
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(distance.rounded()))")
                            .font(.numeralFree(44, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .liveNumber()
                        Text("м").font(.rounded(20, .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                proximityBar
                detailsRow
                HStack(spacing: 12) {
                    muteButton
                    ReportButton(source: .phoneAlert)
                }
                hideButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .background {
                // Полоса цвета типа сверху — тот же сигнал, что у полного экрана.
                ZStack(alignment: .top) {
                    Theme.alertSurface
                    tint.frame(height: 5)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cornerLarge,
                                                  topTrailingRadius: Theme.cornerLarge, style: .continuous))
                .ignoresSafeArea(edges: .bottom)
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onCardEdge($0) }
            .onDisappear { onCardEdge(nil) }
        }
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var proximityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(8, geo.size.width * proximity))
                    .motionAnimation(.linear(duration: 0.9), value: proximity)
            }
        }
        .frame(height: 8)
    }

    /// Скрыть до следующей камеры — отдельной кнопкой, не касанием куда угодно.
    private var hideButton: some View {
        Button(action: onDismiss) {
            Text("Скрыть")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint(Text("До следующей камеры"))
    }

    // MARK: - Блоки

    /// Тип камеры — значком и словом, под ним адрес.
    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.22)).frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.10 : 0.94)
                    // Несколько вдохов и покой: вечный пульс держал
                    // перерисовку на 60 Гц весь показ (аудит 11.10).
                    .motionAnimation(.easeInOut(duration: 0.9).repeatCount(5, autoreverses: true), value: pulse)
                CameraIcon(kind: camera.kind, side: 72)
            }
            VStack(spacing: 4) {
                Text(camera.kind.displayName)
                    .font(.rounded(22, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if !camera.location.isEmpty {
                    Text(camera.location)
                        .font(.rounded(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
        }
    }

    /// Расстояние — самое крупное на экране, под ним полоса приближения.
    private var distanceBlock: some View {
        VStack(spacing: 18) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(Int(distance.rounded()))")
                    .font(.numeralFree(112, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                Text("м").font(.numeral(34, .bold)).foregroundStyle(Theme.textSecondary)
            }
            proximityBar
                .padding(.horizontal, 12)
        }
    }

    /// Направление и скорость со знаком лимита: скорость красная при превышении.
    private var detailsRow: some View {
        HStack(spacing: 12) {
            if let rel = relativeBearing {
                chip {
                    Image(systemName: "location.north.fill")
                        .font(.rounded(16, .bold))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(CameraDirection.arrowAngle(relativeBearing: rel)))
                    Text(directionText(rel))
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            chip {
                if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                    SpeedLimitSign(limit: limit, diameter: 30, isAssumed: env.speedLimits.isCurrentLimitAssumed)
                }
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(Int(speedKmh.rounded()))")
                        .font(.numeral(22, .heavy).monospacedDigit())
                        .foregroundStyle(isOverspeeding ? Theme.danger : Theme.textPrimary)
                        .liveNumber()
                    Text("км/ч")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// «Без звука» во всю оставшуюся ширину: голос и сигнал обрываются сразу
    /// (AlertPlayer.hush), вибрация и само окно остаются — камера не исчезает,
    /// она молчит, как и у кнопки звука на карте.
    private var muteButton: some View {
        let muted = env.settings.isMuted
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            env.settings.setMuted(!muted)
            if !muted { env.alerts.hush() }
        } label: {
            Label(muted ? "Включить звук" : "Без звука",
                  systemImage: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    /// «Радар через 220 метров, прямо. Скорость 47 км/ч» — для VoiceOver.
    private var accessibilitySummary: String {
        var text = "\(camera.kind.displayName) — \(Formatting.distance(distance))"
        if let rel = relativeBearing { text += ", \(directionText(rel))" }
        text += ". " + String(format: String(localized: "Скорость %lld км/ч"), Int(speedKmh))
        return text
    }

    private func directionText(_ rel: Double) -> String {
        switch CameraDirection.classify(relativeBearing: rel) {
        case .ahead:       return String(localized: "прямо")
        case .right:       return String(localized: "справа")
        case .behindRight: return String(localized: "сзади справа")
        case .behindLeft:  return String(localized: "сзади слева")
        case .left:        return String(localized: "слева")
        }
    }
}

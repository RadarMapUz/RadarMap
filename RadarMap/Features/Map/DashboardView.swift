//
//  DashboardView.swift
//  RadarMap
//
//  Режим «Спидометр» (тап по HUD): телефон в держателе — огромная скорость,
//  знак лимита и ближайшая камера на весь экран, как приборка радар-детектора.
//  Читается боковым зрением; экран не гаснет, пока режим открыт.
//

import CoreLocation
import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Экранная модель схемы: сцена «север вверху» + анимированная точка
    /// зрения. Живёт, пока открыта приборка.
    @State private var sketch = SketchState()
    /// Настройки прямо с приборки: это экран поездки, и до «голоса о
    /// превышении» или радиуса оповещений с него раньше было не добраться —
    /// приходилось закрывать приборку и искать спрятанные кнопки на карте.
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Штрафное превышение: красное свечение краёв, видное боковым
            // зрением. БЕЗ пульса — вечная анимация на экране экономии жгла бы
            // GPU-композитинг часами; у камеры (короткие секунды) пульс уместен.
            if isFineOverspeed {
                OverspeedVignette(pulses: false)
            }

            // Порядок зон — просьба водителя с реальной поездки: направления
            // (манёвр и схема) — на самом верху, как в настоящем навигаторе;
            // скорость и камера — по центру; всё, что нажимается (стоп,
            // «Радар»), — внизу, под большим пальцем. Мелкие чипы статуса
            // (жара, заряд вне поездки) — тонкой строкой над направлениями.
            VStack(spacing: 0) {
                statusChips
                    .padding(.horizontal, 28)
                    .padding(.top, 10)

                // Манёвр при активном маршруте. Голос и так говорит «через
                // 300 метров направо», но приборка — экран поездки, и взгляд
                // на неё не должен оставлять вопрос «а поворот-то где?».
                if env.route.isActive, let step = env.route.nextStep {
                    maneuverRow(step)
                        .padding(.top, 12)
                }

                // Схема «где камера»: чертим сами, без карты и без сети.
                // Приборка — режим «телефон в держателе», она обязана быть
                // самым дешёвым экраном приложения, а не самым дорогим.
                if let scene = sketch.scene, sketch.hasCourse, !scene.isEmpty {
                    RoadSketchView(scene: scene, state: sketch, tint: alertColor)
                        .frame(height: 200)
                        .padding(.horizontal, 28)
                        .padding(.top, 6)
                        .opacity(min(sketchIsStale ? 0.45 : 1, isParkedDim ? 0.4 : 1))
                        .animation(.easeOut(duration: 0.4), value: sketchIsStale)
                }

                Spacer(minLength: 14)

                VStack(spacing: 18) {
                    speedHero
                        .opacity(isParkedDim ? 0.4 : 1)

                    // Ближайшая камера: дистанция крупно, цвет греется по
                    // уровню тревоги. НЕ гаснет на стоянке никогда: камера —
                    // то, ради чего приложение существует.
                    if let camera = env.location.nearestCamera,
                       let distance = env.location.distanceToNearest {
                        cameraBlock(camera: camera, distance: distance)
                    } else {
                        Label("Камер рядом нет", systemImage: "checkmark.shield.fill")
                            .font(.rounded(18, .semibold))
                            .foregroundStyle(Theme.success)
                            .padding(.vertical, 24)
                    }
                }

                Spacer(minLength: 14)

                VStack(spacing: 12) {
                    // «Радар ещё стоял?» — приборка перекрывает карту целиком, и
                    // вопрос, нарисованный там, сгорал под ней невидимым: водитель
                    // в держателе не видел его НИКОГДА. Здесь своя копия; на карте
                    // плашка в это время ждёт (isCovered), таймер не двоится.
                    MobileConfirmBar()
                    // «Что это было?» — уточнение типа после «Радар!»: кнопка
                    // прямо под этой плашкой, водитель смотрит именно сюда.
                    ReportRefineBar()

                    if env.location.isTripActive {
                        tripRow
                    }

                    // Кнопка «Радар!» — во всю ширину: тап делается вслепую, и
                    // промахнуться мимо широкой капсулы сложнее, чем мимо квадрата.
                    ReportRadarButton(isLarge: true)

                    Text("Нажмите, чтобы вернуться к карте")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                .opacity(isParkedDim ? 0.4 : 1)
            }
            // Стояночное затемнение (как у Waze): стоим >30 с без тревоги —
            // белые пиксели гаснут до 40%, на OLED это настоящие ватты.
            // Тронулись — мгновенно ярко (isStandingStill пишется на смене).
            .animation(.easeInOut(duration: 0.8), value: isParkedDim)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .statusBarHidden()
        // Тик GPS → точка зрения схемы (и изредка пересборка её растра).
        // Только пока экран телефона действительно на виду: fullScreenCover в
        // фоне не размонтируется, и без этого гейта приборка всю поездку в
        // кармане пересчитывала схему дороги раз в секунду — рисуя в никуда.
        .onChange(of: env.location.locationTick) {
            guard env.isPhoneSceneActive else { return }
            sketch.refresh(env)
        }
        // Приборка светится всю поездку — но по тумблеру пользователя: раньше
        // автопереход молча перебивал выключенное «не гасить экран», отменяя
        // единственный рычаг против главного потребителя.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = env.settings.keepScreenOn
            // Пока водитель смотрит на схему, фиксы нужны чаще: крейсерские
            // 25 м — это рывок раз в 2–3 секунды. Буст снимается сам при
            // закрытии и не включается в перегрев (см. tuneAdaptiveAccuracy).
            env.location.setDashboardVisible(true)
            sketch.refresh(env)
        }
        .onDisappear {
            // Закрыли спидометр в активной поездке — экран продолжает держать
            // поездка; за рулём CarPlay телефон показывает экран передачи и
            // обязан уметь гаснуть.
            UIApplication.shared.isIdleTimerDisabled =
                env.location.isTripActive && env.settings.keepScreenOn
                && !env.isCarPlayConnected
            env.location.setDashboardVisible(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Спидометр"))
        .accessibilityHint(Text("Нажмите, чтобы вернуться к карте"))
    }

    /// Тонкая строка статуса над направлениями: спутники и жара слева, заряд
    /// справа. Вне поездки заряд показываем отдельным чипом — приборка
    /// строилась ради батареи, и её экран — то место, где заряд должен быть
    /// виден всегда (в поездке он уже в строке поездки внизу, не дублируем).
    private var statusChips: some View {
        HStack(spacing: 8) {
            // Сигнал протух (тоннель, паркинг): скорость и дистанции на
            // экране — последнее известное, а не происходящее. Честнее
            // сказать это, чем показывать замершие цифры как живые.
            if env.location.isSignalStale {
                statusChip("Ждём спутники", symbol: "location.slash.fill")
            }
            if env.thermal.mode != .full { thermalChip }
            Spacer()
            if !env.location.isTripActive { BatteryChip() }
            // Шестерёнка живёт в строке всегда: кнопка выигрывает тап у
            // фонового «нажмите, чтобы вернуться» сама, слоёв не нужно.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Настройки"))
        }
    }

    /// Чип статуса в стиле термочипа — жёлтая капсула с иконкой.
    private func statusChip(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.rounded(12, .medium))
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.warning.opacity(0.12), in: Capsule())
    }

    /// Манёвр — верхний баннер, как в навигаторе: иконка + дистанция + фраза.
    private func maneuverRow(_ step: RouteStep) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(26, .bold))
                .foregroundStyle(Theme.accent)
            Text(Formatting.distance(env.route.nextStepDistance))
                .font(.rounded(30, .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(step.text)
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 28)
    }

    /// Жара: троттлинг уже работает (бюджет сетки схемы, буст GPS погашен) —
    /// но молча. Молчаливая деградация читается как поломка, один чип
    /// честности дешевле жалобы «лагает».
    private var thermalChip: some View {
        statusChip("Жарко — экономлю экран", symbol: "thermometer.sun.fill")
    }

    /// Скорость — главное, во весь экран.
    private var speedHero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                Text("\(Int(env.location.speedKmh.rounded()))")
                    .font(.system(size: 148, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(speedColor)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: Int(env.location.speedKmh))
                if let limit = env.speedLimits.currentLimit {
                    SpeedLimitSign(limit: limit, diameter: 84)
                        .scaleEffect(env.speedLimits.isOverspeeding ? 1.08 : 1)
                        // Шесть качков и стоп: «пока превышаешь» на трассе —
                        // это десятки минут, а вечная анимация на экране
                        // экономии — GPU-композитинг часами (та же причина,
                        // по которой кромка приборки без пульса).
                        .animation(env.speedLimits.isOverspeeding
                                   ? .easeInOut(duration: 0.55).repeatCount(6, autoreverses: true)
                                   : .easeOut(duration: 0.25),
                                   value: env.speedLimits.isOverspeeding)
                }
            }
            Text("км/ч")
                .font(.rounded(18, .medium))
                .foregroundStyle(Theme.textTertiary)
                // Шрифт в 148 pt оставляет под цифрами пустой свес строки —
                // подтягиваем подпись под сами цифры, а не под строку.
                .padding(.top, -26)
        }
    }

    /// Строка поездки: время · путь · камеры, заряд и «Стоп». Приборка — экран
    /// поездки, с неё не должно приходиться уходить: ни чтобы посмотреть,
    /// сколько едем, ни чтобы завершить.
    private var tripRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                if let started = env.trip.startedAt {
                    // Системный таймер: тикает сам, без пересборки body каждую секунду.
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.rounded(20, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.success)
                }
                HStack(spacing: 4) {
                    Text(Formatting.distance(env.trip.distanceMeters))
                        .contentTransition(.numericText())
                    Text("·")
                    Image(systemName: "camera.fill")
                        .font(.rounded(10, .semibold))
                    Text("\(env.trip.camerasPassed)")
                        .contentTransition(.numericText())
                }
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            BatteryChip(sinceStartPercent: env.trip.startBatteryPercent)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Тот же путь, что стоп на карте; приборку закроет сам конец
                // поездки (MapScreen прячет её по isTripActive).
                env.location.endTrip()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.rounded(16, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.danger.gradient,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel(Text("Завершить поездку"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// Схема нарисована по устаревшему курсу (стоим, курса нет) — показываем
    /// приглушённо: «это последнее, что мы знали», а не «это происходит
    /// сейчас». Проверено на симуляции: раньше схема на остановке исчезала
    /// целиком, то есть панель гасла бы на каждом светофоре.
    private var sketchIsStale: Bool { env.location.currentCourse < 0 }

    /// Блок ближайшей камеры.
    ///
    /// Раньше здесь были только дистанция и КЛАСС устройства
    /// («Интеллектуальная камера + радар») — то есть экран не отвечал ни на
    /// один вопрос, который водитель задаёт первым: где она, какая именно,
    /// приближаюсь ли. Приборка при этом единственный экран, сделанный ровно
    /// для взгляда из держателя, и единственный, который не спрашивал у
    /// `CameraDirection` направление, хотя панель, плашка сближения и CarPlay
    /// давно спрашивают.
    @ViewBuilder
    private func cameraBlock(camera: Camera, distance: CLLocationDistance) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                // Иконка со стрелкой направления: вверх — прямо по ходу
                // движения, вбок — реальный азимут. Не компас: водителю нужно
                // «слева или справа от меня», а не «где север».
                ZStack {
                    Image(systemName: camera.kind.symbolName)
                        .font(.rounded(26, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(camera.kind.tint.gradient, in: Circle())
                    if let rel = env.location.displayBearingToNearest {
                        let angle = CameraDirection.arrowAngle(relativeBearing: rel)
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(alertColor)
                            .offset(y: -37)
                            .rotationEffect(.degrees(angle))
                            // Шаг в 10° — стрелка не дрожит от шума курса.
                            .animation(.easeOut(duration: 0.3), value: Int(angle / 10))
                    }
                }
                Text(Formatting.distance(distance))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alertColor)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: Int(distance))
                if let side = env.location.nearestSideWord {
                    Text(side)
                        .font(.rounded(20, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Адрес, а не класс железа: на вопрос «какая именно камера»
            // отвечает место. Тип уходит второй строкой — он и так виден
            // по иконке и цвету.
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    if env.location.isOnActiveRoute(camera) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    // Две строки, а не одна: адреса в базе длинные
                    // («4R21 Toshkent Aylanma Yo'li "Qozog'iston Gilamlari"
                    // Qarshisi»), и обрезанные многоточием они не отвечают
                    // на вопрос «какая именно камера» вообще.
                    Text(camera.displayTitle)
                        .font(.rounded(18, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Text(camera.isApproximate
                     ? String(localized: "координата приблизительная")
                     : camera.kind.displayName)
                    .font(.rounded(13))
                    .foregroundStyle(camera.isApproximate ? Theme.warning : Theme.textTertiary)
            }
            .padding(.horizontal, 12)

            // Полосу показываем только внутри радиуса: снаружи она всё равно
            // пуста, а пустая шкала читается как сломанная.
            if distance <= AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                       baseRadius: env.settings.alertRadius) {
                approachBar(distance: distance)
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(alertColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 28)
    }

    /// Полоса сближения. Число говорит «сколько метров», полоса — «приближаюсь»:
    /// это разные сведения, и второе читается вообще без чтения.
    private func approachBar(distance: CLLocationDistance) -> some View {
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius)
        let progress = max(0, min(1, 1 - distance / max(radius, 1)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(alertColor)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .animation(.easeOut(duration: 0.3), value: Int(progress * 50))
        .accessibilityHidden(true)   // цифру рядом VoiceOver уже читает
    }

    private var speedColor: Color {
        guard let limit = env.speedLimits.currentLimit else { return .white }
        let over = env.location.speedKmh - Double(limit)
        if over <= 2 { return .white }
        if FineSchedule.fine(overKmh: over) == 0 { return Theme.role(.attention) }
        return Theme.danger
    }

    /// Превышение уже стоит денег — то же условие, что красит скорость красным.
    private var isFineOverspeed: Bool {
        guard let limit = env.speedLimits.currentLimit else { return false }
        return FineSchedule.fine(overKmh: env.location.speedKmh - Double(limit)) > 0
    }

    /// Стояночное затемнение: долгая стоянка И тихо. Любая тревога возвращает
    /// полную яркость — камера всегда важнее экономии.
    private var isParkedDim: Bool {
        env.location.isStandingStill && env.location.alertLevel == 0
    }

    private var alertColor: Color {
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius)
        // Три ступени: вплотную — опасность, в средней зоне — внимание,
        // в радиусе — нейтральный акцент. Раньше вторая ветка звала
        // Theme.role(.alarm) — тот же danger, и эскалация была двухступенчатой.
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        if distance <= radius { return Theme.accent }
        return Theme.accent
    }
}

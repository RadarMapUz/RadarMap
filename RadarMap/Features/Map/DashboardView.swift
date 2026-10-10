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
            DashFineVignette()
            // Тик GPS → точка зрения схемы. Отдельной вью: прочитанный в корне
            // locationTick пересобирал ВСЮ приборку каждую секунду
            // (docs/perf_audit_2026-10-07.md).
            SketchTickDriver(sketch: sketch)

            // Порядок зон — просьба водителя с реальной поездки: направления
            // (манёвр и схема) — на самом верху, как в настоящем навигаторе;
            // скорость и камера — по центру; всё, что нажимается (стоп,
            // «Радар»), — внизу, под большим пальцем. Мелкие чипы статуса
            // (жара, заряд вне поездки) — тонкой строкой над направлениями.
            //
            // На коротком экране (iPhone SE, 667 pt — телефон владельца) всё
            // это в полный рост не помещалось: схема 200, цифра 148 pt, камера
            // 56 pt, «Радар» 62 — около 830–880 pt, и стопка вылезала за оба
            // края вместе с «Радар» и «Стоп». Теперь на низком экране цифры
            // мельче, а схема — единственная гибкая часть: она сжимается
            // первой (layoutPriority) и отдаёт место скорости, камере и кнопкам.
            GeometryReader { geometry in
            let compact = geometry.size.height < AppConfig.dashCompactHeight
            VStack(spacing: 0) {
                statusChips
                    .padding(.horizontal, 28)
                    .padding(.top, 10)

                // Манёвр при активном маршруте. Голос и так говорит «через
                // 300 метров направо», но приборка — экран поездки, и взгляд
                // на неё не должен оставлять вопрос «а поворот-то где?».
                DashManeuverRow()

                // Схема «где камера»: чертим сами, без карты и без сети.
                // Приборка — режим «телефон в держателе», она обязана быть
                // самым дешёвым экраном приложения, а не самым дорогим.
                DashSketch(sketch: sketch, dimmed: isParkedDim, compact: compact)
                    .layoutPriority(-1)

                Spacer(minLength: compact ? 8 : 14)
                    .layoutPriority(-2)

                VStack(spacing: compact ? 10 : 18) {
                    DashSpeedHero(compact: compact)
                        .opacity(isParkedDim ? 0.4 : 1)

                    // Ближайшая камера: дистанция крупно, цвет греется по
                    // уровню тревоги. НЕ гаснет на стоянке никогда: камера —
                    // то, ради чего приложение существует.
                    DashCameraBlock(compact: compact)
                }

                Spacer(minLength: compact ? 8 : 14)
                    .layoutPriority(-2)

                VStack(spacing: compact ? 8 : 12) {
                    // «Радар ещё стоял?» — приборка перекрывает карту целиком, и
                    // вопрос, нарисованный там, сгорал под ней невидимым: водитель
                    // в держателе не видел его НИКОГДА. Здесь своя копия; на карте
                    // плашка в это время ждёт (isCovered), таймер не двоится.
                    MobileConfirmBar()
                    // «Что это было?» — уточнение типа после «Радар!»: кнопка
                    // прямо под этой плашкой, водитель смотрит именно сюда.
                    ReportRefineBar()

                    if env.location.isTripActive {
                        DashTripRow()
                    }

                    // Кнопка «Радар!» — во всю ширину: тап делается вслепую, и
                    // промахнуться мимо широкой капсулы сложнее, чем мимо квадрата.
                    ReportRadarButton(isLarge: true)
                }
                // Касание мимо кнопок этой зоны НЕ закрывает приборку: тап
                // по экрану — «к карте», и промах мимо «Да»/«Нет» или «Радар»
                // выбрасывал водителя из приборки посреди ответа. Кнопки
                // внутри своё касание получают как раньше.
                .contentShape(Rectangle())
                .onTapGesture {}
                .padding(.horizontal, 28)
                .opacity(isParkedDim ? 0.4 : 1)

                // Подсказка — на коротком экране её место нужнее кнопкам.
                if !compact {
                    Text("Нажмите, чтобы вернуться к карте")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 14)
                        .opacity(isParkedDim ? 0.4 : 1)
                }
            }
            .padding(.bottom, 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
            }
            // Стояночное затемнение (как у Waze): стоим >30 с без тревоги —
            // белые пиксели гаснут до 40%, на OLED это настоящие ватты.
            // Тронулись — мгновенно ярко (isStandingStill пишется на смене).
            .motionAnimation(.easeInOut(duration: 0.8), value: isParkedDim)
        }
        // Приборка тёмная ВСЕГДА, при любой теме приложения: OLED-экономия —
        // смысл этого экрана, и адаптивные токены Theme здесь обязаны
        // разрешаться в ночные значения.
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .statusBarHidden()
        // Приборка светится всю поездку — но по тумблеру пользователя: раньше
        // автопереход молча перебивал выключенное «не гасить экран», отменяя
        // единственный рычаг против главного потребителя.
        .onAppear {
            env.usage.noteScreen("dashboard")
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
        // Раньше .ignore висел на КОРНЕ приборки, и вместе с россыпью цифр
        // VoiceOver терял всё живое внутри: настройки, «Стоп», кнопку отметки
        // радара и вопрос «радар ещё стоял?» с ответами «Да / Нет». Экран,
        // который сам открывается в поездке, оказывался для незрячего
        // водителя одним неподвижным словом «Спидометр».
        // Теперь корень элементом не делаем — сводку цифр берёт на себя сам
        // блок скорости, а кнопки остаются кнопками.
        .accessibilityAction(named: Text("Вернуться к карте")) { dismiss() }
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
                    // 44 pt — не круглое число, а размер подушечки пальца.
                    // Половина промахов на ходу — это кнопка в сорок.
                    .frame(width: 44, height: 44)
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
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.warning.opacity(0.12), in: Capsule())
    }

    /// Жара: троттлинг уже работает (бюджет сетки схемы, буст GPS погашен) —
    /// но молча. Молчаливая деградация читается как поломка, один чип
    /// честности дешевле жалобы «лагает».
    private var thermalChip: some View {
        statusChip("Жарко — экономлю экран", symbol: "thermometer.sun.fill")
    }

    /// Стояночное затемнение: долгая стоянка И тихо. Любая тревога возвращает
    /// полную яркость — камера всегда важнее экономии.
    private var isParkedDim: Bool {
        env.location.isStandingStill && env.location.alertLevel == 0
    }

}

// MARK: - Листья приборки: каждый читает только своё
//
// Корень приборки читал скорость, дистанцию, курс, прогресс маршрута и путь
// поездки — и пересобирался ЦЕЛИКОМ на каждом фиксе, вместе со схемой и
// кнопками (docs/perf_audit_2026-10-07.md). Теперь тиковые значения читают
// только эти листья; корень пересобирается на редких сменах.

/// Правила цвета и превышения — общие для листьев.
private enum DashRules {
    static func speedColor(_ env: AppEnvironment) -> Color {
        guard let limit = env.speedLimits.currentLimit else { return .white }
        let over = env.location.speedKmh - Double(limit)
        if over <= 2 { return .white }
        if FineSchedule.fine(overKmh: over) == 0 { return Theme.role(.attention) }
        return Theme.danger
    }

    /// Превышение уже стоит денег — то же условие, что красит скорость красным.
    static func isFineOverspeed(_ env: AppEnvironment) -> Bool {
        guard let limit = env.speedLimits.currentLimit else { return false }
        return FineSchedule.fine(overKmh: env.location.speedKmh - Double(limit)) > 0
    }

    static func alertColor(_ env: AppEnvironment) -> Color {
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius,
                                                 context: env.location.alertContext)
        // Три ступени: вплотную — опасность, в средней зоне — внимание,
        // в радиусе — нейтральный акцент. Раньше вторая ветка звала
        // Theme.role(.alarm) — тот же danger, и эскалация была двухступенчатой.
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        if distance <= radius { return Theme.accent }
        return Theme.accent
    }
}

/// Тик GPS → точка зрения схемы (и изредка пересборка её растра).
/// Только пока экран телефона действительно на виду: fullScreenCover в
/// фоне не размонтируется, и без этого гейта приборка всю поездку в
/// кармане пересчитывала схему дороги раз в секунду — рисуя в никуда.
private struct SketchTickDriver: View {
    @Environment(AppEnvironment.self) private var env
    let sketch: SketchState

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: env.location.locationTick) {
                guard env.isPhoneSceneActive else { return }
                sketch.refresh(env)
            }
    }
}

/// Штрафное превышение: красное свечение краёв, видное боковым зрением.
/// БЕЗ пульса — вечная анимация на экране экономии жгла бы GPU-композитинг
/// часами; у камеры (короткие секунды) пульс уместен.
private struct DashFineVignette: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if DashRules.isFineOverspeed(env) {
            OverspeedVignette(pulses: false)
        }
    }
}

/// Манёвр при активном маршруте. Голос и так говорит «через 300 метров
/// направо», но приборка — экран поездки, и взгляд на неё не должен
/// оставлять вопрос «а поворот-то где?».
private struct DashManeuverRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.route.isActive, let step = env.route.nextStep {
            maneuverRow(step)
                .padding(.top, 12)
        }
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

}

/// Схема «где камера»: чертим сами, без карты и без сети. Приборка — режим
/// «телефон в держателе», она обязана быть самым дешёвым экраном
/// приложения, а не самым дорогим.
private struct DashSketch: View {
    @Environment(AppEnvironment.self) private var env
    let sketch: SketchState
    let dimmed: Bool
    var compact = false

    var body: some View {
        if let scene = sketch.scene, !scene.isEmpty {
            // Гибкая высота: до 200 (на SE — до 130), а когда места нет —
            // меньше, вплоть до нуля. Скорость, камера и кнопки важнее.
            RoadSketchView(scene: scene, state: sketch, tint: DashRules.alertColor(env),
                           trim: env.thermal.mode.sketchTrim)
                .frame(minHeight: 0, maxHeight: compact ? 130 : 200)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .opacity(min(sketchIsStale ? 0.45 : 1, dimmed ? 0.4 : 1))
                .motionAnimation(.easeOut(duration: 0.4), value: sketchIsStale)
        }
    }

    /// Схема нарисована по устаревшему курсу (стоим, курса нет) — показываем
    /// приглушённо: «это последнее, что мы знали», а не «это происходит
    /// сейчас». Проверено на симуляции: раньше схема на остановке исчезала
    /// целиком, то есть панель гасла бы на каждом светофоре.
    private var sketchIsStale: Bool { env.location.currentCourse < 0 }

}

private struct DashSpeedHero: View {
    @Environment(AppEnvironment.self) private var env
    /// Низкий экран (SE): цифра 112 вместо 148, знак 66 вместо 84.
    var compact = false

    var body: some View { speedHero }

    /// Скорость — главное, во весь экран.
    private var speedHero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                Text("\(Int(env.location.speedKmh.rounded()))")
                    .font(.system(size: compact ? 112 : 148, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(DashRules.speedColor(env))
                    .contentTransition(.numericText())
                    .motionAnimation(.snappy(duration: 0.3), value: Int(env.location.speedKmh))
                if let limit = env.speedLimits.currentLimit {
                    SpeedLimitSign(limit: limit, diameter: compact ? 66 : 84)
                        .scaleEffect(env.speedLimits.isOverspeeding ? 1.08 : 1)
                        // Шесть качков и стоп: «пока превышаешь» на трассе —
                        // это десятки минут, а вечная анимация на экране
                        // экономии — GPU-композитинг часами (та же причина,
                        // по которой кромка приборки без пульса).
                        .motionAnimation(env.speedLimits.isOverspeeding
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
                .padding(.top, compact ? -20 : -26)
        }
        // Одна фраза вместо россыпи цифр — но только на этом блоке, а не на
        // всей приборке: кнопки внутри неё обязаны остаться кнопками.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(speedSummary))
    }

    /// «62 километра в час, ограничение 60, превышение» — то, что человек
    /// прочитал бы с экрана сам.
    private var speedSummary: String {
        var parts = [String(format: String(localized: "%lld километров в час"),
                            Int(env.location.speedKmh.rounded()))]
        if let limit = env.speedLimits.currentLimit {
            parts.append(String(format: String(localized: "ограничение %lld"), limit))
            if env.speedLimits.isOverspeeding { parts.append(String(localized: "превышение")) }
        }
        return parts.joined(separator: ", ")
    }

}

private struct DashCameraBlock: View {
    @Environment(AppEnvironment.self) private var env
    /// Низкий экран (SE): дистанция 44 вместо 56, отступы меньше.
    var compact = false

    var body: some View {
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
                        .foregroundStyle(camera.kind.glyphTint)
                        .frame(width: 54, height: 54)
                        .background(camera.kind.tint.gradient, in: Circle())
                    if let rel = env.location.displayBearingToNearest {
                        let angle = CameraDirection.arrowAngle(relativeBearing: rel)
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DashRules.alertColor(env))
                            .offset(y: -37)
                            .rotationEffect(.degrees(angle))
                            // Шаг в 10° — стрелка не дрожит от шума курса.
                            .motionAnimation(.easeOut(duration: 0.3), value: Int(angle / 10))
                    }
                }
                Text(Formatting.distance(distance))
                    .font(.system(size: compact ? 44 : 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(DashRules.alertColor(env))
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
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
                                                       baseRadius: env.settings.alertRadius,
                                                       context: env.location.alertContext) {
                approachBar(distance: distance)
            }
        }
        .padding(.vertical, compact ? 12 : 18)
        .frame(maxWidth: .infinity)
        .background(DashRules.alertColor(env).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .padding(.horizontal, 28)
    }

    /// Полоса сближения. Число говорит «сколько метров», полоса — «приближаюсь»:
    /// это разные сведения, и второе читается вообще без чтения.
    private func approachBar(distance: CLLocationDistance) -> some View {
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius,
                                                 context: env.location.alertContext)
        let progress = max(0, min(1, 1 - distance / max(radius, 1)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(DashRules.alertColor(env))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .motionAnimation(.easeOut(duration: 0.3), value: Int(progress * 50))
        .accessibilityHidden(true)   // цифру рядом VoiceOver уже читает
    }

}

private struct DashTripRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View { tripRow }

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
            // Тот же путь, что стоп на карте, и то же подтверждение в два
            // касания; приборку закроет сам конец поездки (MapScreen прячет её
            // по isTripActive).
            StopTripButton { env.location.endTrip() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

}

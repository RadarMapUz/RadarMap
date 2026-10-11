//
//  CarPlayOverlay.swift
//  RadarMap
//
//  HUD поверх карты/схемы CarPlay: док (скорость | камера | прибытие),
//  баннеры манёвра и приближения, чип жары.
//
//  Отдельная вью — это изолятор пер-тиковых чтений, тот же принцип, что
//  MapTickGates на телефоне: скорость, дистанции и уровень тревоги меняются
//  каждый GPS-фикс, и пока они читались в body самого экрана, каждый тик
//  переоценивал всё дерево вместе с UIViewRepresentable карты и обеими
//  раскладками ViewThatFits. Здесь пересборка стоит маленький HUD, не карту.
//

import SwiftUI
import MapKit

struct CarPlayOverlay: View {
    @Environment(AppEnvironment.self) private var env
    /// Свой баннер манёвра. Выключен, пока манёвр рисует сама машина
    /// (навигационная сессия CarPlay).
    var showsManeuver = true
    /// Ширина HUD. Меняется только со сменой экрана, а не тиком: решение
    /// «влезает ли третья зона» раньше принимал ViewThatFits, раскладывая обе
    /// версии дока на КАЖДЫЙ фикс (perf-аудит 07.10, п. 12).
    @State private var width: CGFloat = 0

    // MARK: - Раскладка

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if showsManeuver, let step = env.route.nextStep {
                    maneuverBanner(step: step, distance: env.route.nextStepDistance)
                }
                // Камеры наверху нет: до 11.10 тут стоял второй баннер той же
                // камеры, что и в углу снизу, — одна цифра дважды на экране.
                // Тревогу несёт нижняя карточка (кольцо, кромка, тип, знак).
                Spacer(minLength: 0)
            }
            // Состояния, о которых водитель обязан узнать: нет разрешения,
            // нет сети, жара, объявление владельца. Раньше здесь был только
            // чип жары — про серую карту без сети машина молчала.
            HStack {
                CarPlayStatusChips()
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            dock
        }
        // Колонку своих кнопок CarPlay кладёт в safe area, и сторона зависит от
        // системы машины. Раньше здесь стоял отступ 76 pt справа — в машине с
        // кнопками слева панель уехала бы прямо под них.
        //
        // Отступ по ВСЕМ сторонам, а не только по горизонтали: свои кнопки
        // («Куда», предупреждение) CarPlay держит в верхних углах и резервирует
        // под них верхнюю safe area. Пока мы уважали только горизонталь, баннер
        // приближения заезжал под них и обрезался ровно на самом важном — на
        // типе камеры и знаке ограничения.
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .safeAreaPadding()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .motionAnimation(.spring(duration: 0.35), value: env.location.isApproachingCamera)
        .motionAnimation(.spring(duration: 0.35), value: env.route.isActive)
        // HUD — только показывает: жесты карты (тап, панорама, щипок) должны
        // проходить сквозь него в MKMapView.
        .allowsHitTesting(false)
    }

    // MARK: - Приборная панель

    /// Низ экрана: скорость со знаком — кругом в углу, камера и прибытие —
    /// капсулами по размеру своего текста. Как у Amap и Яндекса.
    ///
    /// До 11.10 здесь была одна широкая плашка на три зоны. В CarPlay
    /// Simulator на 800×480 она легла на середину карты — туда, куда смотрят
    /// на дорогу и машину, — и при этом обрезала текст («Камер…» вместо
    /// «Камер рядом нет»): ширина делилась на трети, а не по содержимому.
    /// Теперь элементы занимают ровно свой текст и стоят в левом углу,
    /// напротив системных кнопок карты (они справа), а центр карты свободен.
    private var dock: some View {
        HStack(alignment: .bottom, spacing: 10) {
            speedBadge
            cameraPill
            // Прибытие — только пока манёвр не рисует сама машина: в
            // навигационной сессии время в пути стоит в её карточке.
            if showsManeuver, env.route.isActive, Self.fitsRoute(hudWidth: width) {
                pill { etaCell }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(height: AppConfig.carPlayDockHeight, alignment: .bottom)
        .motionAnimation(.easeOut(duration: 0.3), value: env.location.alertLevel)
    }

    /// Скорость в круге и знак ограничения поверх его угла — сравнение
    /// «еду / можно» одним взглядом, как на приборке. Кольцо круга греется
    /// по превышению: цвет цифры — не единственный носитель.
    private var speedBadge: some View {
        let limit = env.settings.speedLimitsEnabled ? env.speedLimits.currentLimit : nil
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: -2) {
                Text("\(Int(env.location.speedKmh.rounded()))")
                    .font(.rounded(30, .heavy).monospacedDigit())
                    .foregroundStyle(speedColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .liveNumber()
                Text("км/ч")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 78, height: 78)
            // Тень у круга, а не у цифр: `.shadow` на составной вью размывал
            // каждую цифру скорости отдельно и заново на каждом тике GPS.
            .background {
                Circle().fill(Theme.background.opacity(0.94))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            }
            .overlay(Circle().stroke(speedColor == Theme.textPrimary ? Theme.stroke : speedColor,
                                     lineWidth: speedColor == Theme.textPrimary ? 1 : 3))
            if let limit {
                SpeedLimitSign(limit: limit, diameter: 42,
                               isAssumed: env.speedLimits.isCurrentLimitAssumed)
                    .shadow(color: env.speedLimits.isOverspeeding ? Theme.danger.opacity(0.8) : .black.opacity(0.3),
                            radius: env.speedLimits.isOverspeeding ? 9 : 4)
                    .offset(x: 16, y: -12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // Знак выступает за круг — место под него, чтобы капсула камеры не
        // легла на знак.
        .padding(.trailing, limit == nil ? 0 : 16)
        .padding(.top, limit == nil ? 0 : 12)
        .motionAnimation(.spring(duration: 0.3), value: env.speedLimits.currentLimit)
    }

    /// Камера — капсулой по размеру текста; кромка и тень в тон тревоги.
    private var cameraPill: some View {
        pill(edge: dockEdge, edgeWidth: alertTint == nil ? 1 : 3,
             glow: alertTint) { cameraCell }
    }

    /// Общая подложка капсулы низа: тёмное стекло темы, кромка, тень. Размер —
    /// по содержимому (`fixedSize`): обрезать текст ради ровной сетки нельзя.
    private func pill<Content: View>(edge: Color = Theme.stroke, edgeWidth: CGFloat = 1,
                                     glow: Color? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Тень у подложки, а не у содержимого (см. круг скорости выше).
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.background.opacity(0.94))
                    .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.4 : 0.6),
                            radius: glow == nil ? 10 : 16, y: 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(edge, lineWidth: edgeWidth))
    }

    /// Влезает ли третья зона (прибытие): ширина дока — ширина HUD без его
    /// отступов, но не шире потолка острова; минус внутренние поля.
    static func fitsRoute(hudWidth: CGFloat) -> Bool {
        let dock = min(hudWidth - 28, AppConfig.carPlayDockMaxWidth) - 36
        return dock >= AppConfig.carPlayDockThreeZoneWidth
    }

    /// Ближайшая камера — честные состояния: нет сигнала, уточняем положение,
    /// есть цель, чисто.
    ///
    /// «Уточняем положение» появилось потому, что дистанция считается и от
    /// грубой координаты — от фикса, который в алерты не пустили. Зелёный щит
    /// при этом хуже неверной цифры: это утверждение, а не число.
    ///
    /// Вид (11.10): цветной квадрат-значок слева и ОДНА строка там, где хватает
    /// одной. Было «Чисто» крупно и «Камер рядом нет» мелко под ним — две
    /// строки ради одной мысли, и вторая на 800×480 обрезалась до «Камер…».
    @ViewBuilder
    private var cameraCell: some View {
        if env.location.isSignalStale {
            statusCell(symbol: "location.slash.fill", tint: Theme.warning,
                       title: String(localized: "Нет сигнала GPS"))
        } else if let camera = env.location.nearestCamera,
                  let distance = env.location.distanceToNearest,
                  distance <= AppConfig.carPlayNearestCameraMeters {
            nearestCameraCell(camera: camera, distance: distance)
        } else if env.location.isPositionCoarse {
            statusCell(symbol: "location.magnifyingglass", tint: Theme.warning,
                       title: String(localized: "Уточняем положение"))
        } else {
            statusCell(symbol: "checkmark.shield.fill", tint: Theme.success,
                       title: String(localized: "Камер рядом нет"))
        }
    }

    /// Значок карточки: квадрат со скруглением, глиф по центру. Один на все
    /// карточки низа — камера, состояние, прибытие читаются как семья.
    private func glyphTile(_ symbol: String, fill: some ShapeStyle, glyph: Color) -> some View {
        Image(systemName: symbol)
            .font(.rounded(17, .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(glyph)
            .frame(width: 40, height: 40)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nearestCameraCell(camera: Camera, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            ZStack {
                // Кольцо приближения вокруг значка вместо полоски под текстом:
                // заполняется к камере и видно боковым зрением, не занимая
                // строки. По грубой точке не рисуем — там прогресса никто не мерил.
                if !env.location.isPositionCoarse, let progress = env.location.approachProgress {
                    Circle()
                        .stroke(Theme.stroke, lineWidth: 3)
                        .frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.03))
                        .stroke(Theme.role(progress > 0.66 ? .alarm : progress > 0.33 ? .attention : .neutral),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                        .motionAnimation(.easeOut(duration: 0.3), value: progress)
                }
                glyphTile(camera.kind.symbolName,
                          fill: proximityTint(distance, camera).gradient,
                          glyph: proximityGlyph(distance, camera))

                // Стрелка направления на камеру относительно курса (вверх =
                // прямо по ходу): по ходу камера или уводит в сторону.
                if let relative = env.location.relativeBearingToNearest {
                    let angle = CameraDirection.arrowAngle(relativeBearing: relative)
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(camera.kind.tint)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .offset(y: -33)
                        .rotationEffect(.degrees(angle))
                        .motionAnimation(.easeOut(duration: 0.3), value: Int(angle / 10))
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(env.location.isApproachingCamera ? 30 : 24, .heavy)
                        .monospacedDigit())
                    .foregroundStyle(env.location.isPositionCoarse ? Theme.textSecondary
                                     : (env.location.isApproachingCamera ? Theme.danger
                                                                         : Theme.textPrimary))
                    .liveNumber()
                Text(env.location.isPositionCoarse
                     ? String(localized: "уточняем положение")
                     : camera.kind.genitivePhrase)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(env.location.isPositionCoarse ? Theme.warning
                                                                   : Theme.textSecondary)
                    .lineLimit(1)
            }

            // Ограничение У КАМЕРЫ — только когда оно другое, чем знак у
            // скорости: та же цифра рядом дважды — шум, а «камера на 50, едем
            // по 70» — ровно то, ради чего водитель смотрит вниз.
            if env.location.isApproachingCamera,
               let limit = env.speedLimits.limit(near: camera.coordinate),
               limit != env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 40)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .motionAnimation(.easeOut(duration: 0.25), value: env.location.isApproachingCamera)
    }

    private func statusCell(symbol: String, tint: Color, title: String) -> some View {
        HStack(spacing: 10) {
            glyphTile(symbol, fill: tint.opacity(0.18), glyph: tint)
            Text(title)
                .font(.rounded(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    /// Прибытие. Главное число — СКОЛЬКО ЕХАТЬ: это первый вопрос водителя, и
    /// именно его Apple с Google держат героем. Время прибытия и остаток —
    /// строкой ниже; камеры впереди — значком с числом.
    private var etaCell: some View {
        HStack(spacing: 10) {
            glyphTile("flag.checkered", fill: Theme.success.opacity(0.18), glyph: Theme.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.duration(env.route.remainingTime))
                    .font(.rounded(24, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    Text(verbatim: "\(env.route.arrivalDate.formatted(date: .omitted, time: .shortened)) · \(Formatting.distance(env.route.remainingDistance))")
                        .font(.rounded(13, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    if camerasAhead > 0 {
                        Label("\(camerasAhead)", systemImage: "camera.fill")
                            .font(.rounded(13, .bold).monospacedDigit())
                            .foregroundStyle(Theme.Types.camera)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    /// Сколько камер маршрута ещё впереди (пройденные не считаем).
    private var camerasAhead: Int {
        let progress = env.route.progressAlong
        // count(where:) вместо filter().count: считается на каждый тик GPS, а
        // промежуточный массив камер маршрута тут не нужен никому.
        return env.route.camerasOnRoute.count { $0.distanceAlong > progress }
    }

    // MARK: - Верхние баннеры

    /// Манёвр: «через 300 м — направо на Амира Темура».
    ///
    /// Сама инструкция — первичный текст, дистанция — вторичный по цвету:
    /// водитель ищет глазами «куда», а не «сколько». Раньше было наоборот —
    /// имя улицы стояло самым мелким текстом баннера (12 pt), при том что
    /// у Google и Apple именно оно доминирует.
    /// Синяя карточка с белым текстом — та же, что на телефоне (вариант А,
    /// 10.10): манёвр узнаётся одним видом на обоих экранах.
    private func maneuverBanner(step: RouteStep, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(24, .bold))
                .foregroundStyle(Theme.onAccentFill)
                .frame(width: 50, height: 50)
                .background(Theme.onAccentFill.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.onAccentFill)
                    .liveNumber()
                Text(step.text)
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.onAccentFillSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .layoutPriority(0)
        // Тень у карточки, а не у расстояния до манёвра поверх неё.
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.accentFill)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.onAccentFill.opacity(0.12), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Цвета и мелочи

    /// Цвет тревоги по уровню эскалации: янтарь → оранжевый → красный.
    /// nil — тревоги нет, кромка панели остаётся нейтральной.
    private var alertTint: Color? {
        switch env.location.alertLevel {
        case 1:  return Theme.role(.attention)
        case 2:  return Theme.warning
        case 3...: return Theme.role(.alarm)
        default: return nil
        }
    }

    private var dockEdge: Color { alertTint ?? Theme.stroke }

    /// Цвет скорости: белый в рамках лимита, янтарный при превышении без штрафа,
    /// красный — когда превышение уже стоит денег.
    private var speedColor: Color {
        guard env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit else {
            return Theme.textPrimary
        }
        // Одно правило на всё приложение: одна ситуация — один цвет.
        switch Theme.speedLevel(speedKmh: env.location.speedKmh, limitKmh: limit,
                                tolerance: env.settings.overspeedTolerance) {
        case .normal, .neutral: return Theme.textPrimary
        case .attention:        return Theme.warning
        case .alarm:            return Theme.danger
        }
    }

    /// Цвет значка камеры по БЛИЗОСТИ, а не по типу: красный кружок при камере
    /// в трёх километрах читается как тревога, хотя ехать до неё минуты.
    /// Значок поверх `proximityTint`: на цвете типа — его glyphTint (тёмный на
    /// светлом радаре), на сером «далеко» — контрастный фону темы.
    private func proximityGlyph(_ distance: CLLocationDistance, _ camera: Camera) -> Color {
        distance <= env.location.effectiveAlertRadius * 3
            ? camera.kind.glyphTint : Theme.background
    }

    private func proximityTint(_ distance: CLLocationDistance, _ camera: Camera) -> Color {
        let radius = env.location.effectiveAlertRadius
        if distance <= radius { return camera.kind.tint }
        if distance <= radius * 3 { return camera.kind.tint.opacity(0.55) }
        return Theme.textTertiary
    }
}

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
    /// Сколько занимают кнопки карты по краям окна (CarPlayWindowRoot →
    /// mapButtonSafeAreaLayoutGuide): док у правого края встаёт левее них.
    var buttonInsets = EdgeInsets()
    /// Ведение на паузе «Нет сигнала GPS» — плашку об этом рисует система.
    var systemLocating = false
    /// Безопасная зона окна — от неё уже отступает весь HUD.
    @State private var safe = EdgeInsets()
    /// Ширина HUD. Меняется только со сменой экрана, а не тиком: решение
    /// «влезает ли третья зона» раньше принимал ViewThatFits, раскладывая обе
    /// версии дока на КАЖДЫЙ фикс (perf-аудит 07.10, п. 12).
    @State private var width: CGFloat = 0

    /// Свой манёвр и прибытие — только в ведении (NavigationFlow): маршрут
    /// без поездки — это выбор с «Поехали» на телефоне, а не «через 300 м
    /// направо» без голоса (сценарий D1, 20.10).
    private var isGuiding: Bool {
        NavigationFlow.phase(hasRoute: env.route.isActive, isTripActive: env.location.isTripActive) == .guiding
    }

    // MARK: - Раскладка

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if showsManeuver, isGuiding, let step = env.route.nextStep {
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
                CarPlayStatusChips(systemLocating: systemLocating)
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
        // Безопасную зону окна HUD уважает сам (он не игнорирует её, в
        // отличие от карты под ним); `.safeAreaPadding()` без длины добавлял
        // к ней ещё системные ~16 pt с каждой стороны — на 800×480 это треть
        // высоты баннера манёвра (10.7).
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safe = $0 }
        .motionAnimation(Motion.standard, value: env.route.isActive)
        // HUD — только показывает: касаний в окне машины нет (осмотр и зум
        // приходят командами шаблона), и ничего перехватывать он не должен.
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
    /// Теперь элементы занимают ровно свой текст.
    ///
    /// С 12.10 док — у ПРАВОГО края, вплотную слева от кнопок карты, а не
    /// у левого края безопасной зоны. В навигации левый край зоны начинается
    /// сразу за системными карточками (манёвр, прибытие), и док вставал
    /// посреди карты — на дорогу перед машиной («расположены вещи не
    /// правильно», владелец, 12.10). Справа он группируется с кнопками, а
    /// скорость со знаком лимита стоит крайней — одно место для «еду/можно».
    ///
    /// С 21.10 камеры в доке нет (CarPlayCameraCue): Руководство CarPlay
    /// (стр. 7, 36) своих панелей поверх карты не любит, Waze и Google Maps
    /// держат в углу только скорость с лимитом, а о камере говорят системный
    /// баннер и подпись «400 м» у её значка на самой карте. Док — скорость со
    /// знаком; прибытие или призрак — только пока их не рисует сама машина.
    private var dock: some View {
        let items = CarPlayCameraCue.dock(ownArrival: showsManeuver && isGuiding && env.route.isActive,
                                          hasRoute: env.route.isActive,
                                          hasGhost: env.commuteLive.display != nil,
                                          fitsSecond: Self.fitsRoute(hudWidth: width))
        return HStack(alignment: .bottom, spacing: 10) {
            Spacer(minLength: 0)
            if items.contains(.arrival) {
                pill { etaCell }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if items.contains(.ghost), let ghost = env.commuteLive.display {
                // Дорога на работу без маршрута (8.8.3б): прибытие по своим
                // поездкам — на месте капсулы прибытия маршрута.
                pill { ghostCell(ghost) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            speedBadge
        }
        // Левее кнопок карты: HUD уже отступил на безопасную зону и 14 pt,
        // добираем до ширины колонки кнопок и 8 pt воздуха.
        .padding(.trailing, max(0, buttonInsets.trailing + 8 - safe.trailing - 14))
        .frame(height: AppConfig.carPlayDockHeight, alignment: .bottom)
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
                // Свечение — параметром знака (тень на его круге), не `.shadow`
                // снаружи: та размывала круг, кольцо и каждую цифру отдельно
                // и пересчитывалась над картой машины на каждом фиксе.
                SpeedLimitSign(limit: limit, diameter: 42,
                               isAssumed: env.speedLimits.isCurrentLimitAssumed,
                               glow: isOver ? Theme.danger.opacity(0.8) : .black.opacity(0.3),
                               glowRadius: isOver ? 9 : 4)
                    .offset(x: 16, y: -12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // Знак выступает за круг — место под него, чтобы капсула камеры не
        // легла на знак.
        .padding(.trailing, limit == nil ? 0 : 16)
        .padding(.top, limit == nil ? 0 : 12)
        .motionAnimation(Motion.standard, value: env.speedLimits.currentLimit)
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
                    Text(verbatim: "\(Formatting.clock(env.route.arrivalDate)) · \(Formatting.distance(env.route.remainingDistance))")
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

    /// Призрак: «9:12» крупно, «Работа · +4 мин к обычному» мелко — те же
    /// слова, что на панели поездки телефона (GhostText).
    private func ghostCell(_ ghost: CommuteLiveService.Display) -> some View {
        HStack(spacing: 10) {
            glyphTile(GhostText.symbol(ghost), fill: Theme.accent.opacity(0.18), glyph: Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(ghost.arrival, style: .time)
                    .font(.rounded(24, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                // Длинная подпись («Работа · на 12 мин позже 9:00 · пробка») не
                // раздвигает док под кнопки карты: потолок ширины капсулы.
                Text(verbatim: GhostText.caption(ghost))
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(GhostText.tint(ghost))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: AppConfig.carPlayGhostCaptionMaxWidth, alignment: .leading)
            }
        }
    }

    /// Сколько камер маршрута ещё впереди (пройденные не считаем).
    private var camerasAhead: Int {
        let progress = env.route.progressAlong
        // count(where:) вместо filter().count: считается на каждый тик GPS, а
        // промежуточный массив камер маршрута тут не нужен никому.
        // Только свои (29.E): встречная камера проспекта — не «впереди у нас».
        return env.route.camerasOnRoute.count { $0.countsAsOurs && $0.distanceAlong > progress }
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
                Text(step.compactInstruction)
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

    /// Превышение — то же правило, что у знака рядом, плитки и телефона
    /// (`OverspeedThreshold.showsOverspeed`): до 22.10 цифра здесь красилась
    /// по штрафной шкале, и при 64 в зоне 60 знак был красным, а цифра белой.
    private var isOver: Bool {
        OverspeedThreshold.showsOverspeed(
            limitShown: env.settings.speedLimitsEnabled ? env.speedLimits.currentLimit : nil,
            isOverspeeding: env.speedLimits.isOverspeeding)
    }

    /// Цвет скорости: обычный в рамках лимита, красный при превышении.
    private var speedColor: Color { isOver ? Theme.danger : Theme.textPrimary }
}

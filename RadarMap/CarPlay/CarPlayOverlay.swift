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
                Spacer(minLength: 0)
                if let camera = env.location.nearestCamera,
                   let distance = env.location.distanceToNearest,
                   env.location.isApproachingCamera {
                    approachBanner(camera: camera, distance: distance)
                }
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

    /// Полоса внизу: скорость | ближайшая камера | прибытие. Высота фиксирована
    /// (AppConfig.carPlayDockHeight) — на эту же величину карта поджимает свои
    /// служебные подписи, чтобы «Правовые документы» не оказались под панелью.
    private var dock: some View {
        // Экраны в машинах разные — от узких 800×480 до широких. Прибытие
        // отваливается первым: без него панель остаётся полезной, а вот резать
        // скорость и камеру нельзя. И его нет, пока идёт навигационная сессия:
        // время в пути тогда показывает сама машина под карточкой манёвра.
        dockRow(showRoute: showsManeuver
                && Self.fitsRoute(hudWidth: width))
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: AppConfig.carPlayDockHeight)
        // Подкраска в тон тревоги ПОД содержимым, но НАД тёмной подложкой:
        // с 70 см кромку-нитку не видно, а тонированная плашка читается
        // боковым зрением как «внизу что-то происходит».
        .background((alertTint ?? .clear).opacity(alertTint == nil ? 0 : 0.07),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Theme.background.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Кромка панели окрашивается по тревоге: боковым зрением видно, что
        // впереди камера, даже если смотришь на дорогу, а не на цифры.
        // 3.5, а не 2: двухточечная кромка с торпеды — нитка.
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(dockEdge, lineWidth: alertTint == nil ? 1 : 3.5))
        // Тень в тон тревоги — «нимб», который виден краем глаза даже там,
        // где сама плашка перекрыта рукой на руле.
        .shadow(color: (alertTint ?? .black).opacity(alertTint == nil ? 0.45 : 0.6),
                radius: alertTint == nil ? 14 : 20, y: 6)
        // Остров, а не лента: на экране в 1900 точек зоны, растянутые по
        // третям всей ширины, разъезжаются на полэкрана — глазу приходится
        // пробегать весь дисплей, чтобы собрать «скорость—камера—прибытие».
        // Капим ширину и центрируем: на обычных экранах ничего не меняется.
        .frame(maxWidth: AppConfig.carPlayDockMaxWidth)
        .frame(maxWidth: .infinity)
        .motionAnimation(.easeOut(duration: 0.3), value: env.location.alertLevel)
    }

    /// Влезает ли третья зона (прибытие): ширина дока — ширина HUD без его
    /// отступов, но не шире потолка острова; минус внутренние поля.
    static func fitsRoute(hudWidth: CGFloat) -> Bool {
        let dock = min(hudWidth - 28, AppConfig.carPlayDockMaxWidth) - 36
        return dock >= AppConfig.carPlayDockThreeZoneWidth
    }

    /// Три зоны: скорость — камера — прибытие.
    ///
    /// Главное правило — акцент отдаётся СРОЧНОМУ, а не постоянному. Пока
    /// едем спокойно, крупная цифра одна: скорость. Как только впереди камера,
    /// центральная зона получает заливку и вес, а скорость уходит на второй
    /// план — за рулём глаз должен сразу знать, что читать первым, а до этого
    /// обе цифры были набраны почти одинаково и конкурировали.
    /// Каждая зона стоит по центру своей доли панели.
    ///
    /// Прижатыми влево они оставляли пустой правую треть; прижатыми к краям —
    /// дыру посередине, и на настоящем экране машины эта дыра оказалась в
    /// семьсот точек, то есть шире любой из зон. Центрирование в своей доле
    /// даёт единственную раскладку, которая ровна при любом числе зон: поля
    /// распределяются симметрично, а не собираются в одном месте.
    private func dockRow(showRoute: Bool) -> some View {
        let withRoute = showRoute && env.route.isActive
        return HStack(spacing: 0) {
            speedCell
                .frame(maxWidth: .infinity)
            cameraCell
                .frame(maxWidth: .infinity)
            if withRoute {
                etaCell
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // Разделителей-ниток между зонами больше нет.
    //
    // Линия в один пункт с торпеды не видна — ровно та же причина, по которой
    // кромка панели здесь 3,5, а не 2. Зоны разделяет заливка: у камеры на
    // подходе своя панель состояния, у остальных — воздух.

    /// Скорость крупно + знак лимита рядом: сравнение «еду / можно» одним взглядом.
    ///
    /// Кегль скорости ПОСТОЯННЫЙ. Раньше при камере цифра сжималась 38→30,
    /// уступая акцент дистанции, — но скорость нужна водителю сильнее всего
    /// именно у камеры: он сравнивает «еду/можно» в момент решения тормозить.
    /// Waze и Google размер спидометра не трогают никогда. Акцент камере уже
    /// дают красная подложка её зоны и выросшая дистанция.
    private var speedCell: some View {
        HStack(spacing: 12) {
            VStack(spacing: -1) {
                // Кегль 46 — решение, принятое по макету, а не по инерции.
                //
                // История числа поучительна. В коде стояло 38, но прежняя
                // шкала обрезалась потолком 30, и все эти месяцы цифра
                // рисовалась ТРИДЦАТОЙ — раскладку панели подгоняли в машине
                // именно под неё. Новая шкала молча вернула 38; я откатил к
                // 30 как к тому, что реально видел водитель.
                //
                // На макете стало видно, что 30 было мало с самого начала.
                // Экран машины смотрят с семидесяти сантиметров: тридцать
                // пунктов оттуда — это примерно двенадцать с вытянутой руки.
                // Скорость здесь главная цифра, её сравнивают со знаком в
                // момент решения тормозить.
                Text("\(Int(env.location.speedKmh.rounded()))")
                    .font(.rounded(46, .heavy).monospacedDigit())
                    .foregroundStyle(speedColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .motionAnimation(.snappy(duration: 0.25), value: Int(env.location.speedKmh.rounded()))
                Text("км/ч")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minWidth: 58)

            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 52,
                               isAssumed: env.speedLimits.isCurrentLimitAssumed)
                    .shadow(color: env.speedLimits.isOverspeeding ? Theme.danger.opacity(0.8) : .clear,
                            radius: 9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .motionAnimation(.spring(duration: 0.3), value: env.speedLimits.currentLimit)
    }

    /// Ближайшая камера — честные состояния: нет сигнала, уточняем положение,
    /// есть цель, чисто.
    ///
    /// «Уточняем положение» появилось потому, что дистанция считается и от
    /// грубой координаты — от фикса, который в алерты не пустили. Телефонный
    /// HUD такое расстояние приглушает и подписывает, а док машины показывал
    /// его так же уверенно, как живое. Зелёный щит «Чисто» при этом ещё хуже
    /// неверной цифры: это утверждение, а не число.
    @ViewBuilder
    private var cameraCell: some View {
        if env.location.isSignalStale {
            statusCell(symbol: "location.slash.fill", tint: Theme.warning,
                       title: String(localized: "Нет сигнала"),
                       subtitle: String(localized: "Ждём спутники"))
        } else if let camera = env.location.nearestCamera,
                  let distance = env.location.distanceToNearest,
                  distance <= AppConfig.carPlayNearestCameraMeters {
            nearestCameraCell(camera: camera, distance: distance)
        } else if env.location.isPositionCoarse {
            statusCell(symbol: "location.magnifyingglass", tint: Theme.warning,
                       title: String(localized: "Уточняем положение"),
                       subtitle: String(localized: "Расстояние пока приблизительное"))
        } else {
            statusCell(symbol: "checkmark.shield.fill", tint: Theme.success,
                       title: String(localized: "Чисто"),
                       subtitle: String(localized: "Камер рядом нет"))
        }
    }

    private func nearestCameraCell(camera: Camera, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: camera.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(proximityGlyph(distance, camera))
                    .frame(width: 38, height: 38)
                    .background(proximityTint(distance, camera).gradient, in: Circle())

                // Стрелка направления на камеру относительно курса (вверх = прямо
                // по ходу): понятно, камера впереди или уводит в сторону.
                // 12 pt и тёмная тень: девятипунктовый треугольник с торпеды
                // неразличим, а отвечает он на важный вопрос «по ходу или вбок».
                if let relative = env.location.relativeBearingToNearest {
                    let angle = CameraDirection.arrowAngle(relativeBearing: relative)
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(camera.kind.tint)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .offset(y: -28)
                        .rotationEffect(.degrees(angle))
                        .motionAnimation(.easeOut(duration: 0.3), value: Int(angle / 10))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(Formatting.distance(distance))
                    .font(.rounded(env.location.isApproachingCamera ? 30 : 24, .heavy)
                        .monospacedDigit())
                    .foregroundStyle(env.location.isPositionCoarse ? Theme.textSecondary
                                     : (env.location.isApproachingCamera ? Theme.danger
                                                                         : Theme.textPrimary))
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                Text(env.location.isPositionCoarse
                     ? String(localized: "уточняем положение")
                     : camera.kind.genitivePhrase)
                    .font(.rounded(14, .medium))
                    .foregroundStyle(env.location.isPositionCoarse ? Theme.warning
                                                                   : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Полоса приближения считается от живой точки: по грубой она
                // рисовала бы уверенный прогресс там, где его никто не мерил.
                if !env.location.isPositionCoarse, let progress = env.location.approachProgress {
                    approachBar(progress)
                }
            }
        }
        // Подложка появляется только на подходе: она и есть сигнал «читай
        // сюда». В спокойной езде зона выглядит так же тихо, как соседние.
        .padding(.horizontal, env.location.isApproachingCamera ? 12 : 0)
        .padding(.vertical, env.location.isApproachingCamera ? 6 : 0)
        .background {
            if env.location.isApproachingCamera {
                // Градиент, а не плоская краска: тот же язык, что у карточек
                // телефона (`statePanel`). С семидесяти сантиметров перепад
                // светлоты читается, а ровная подложка сливается с панелью.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.danger.opacity(0.24),
                                                  Theme.danger.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.danger.opacity(0.40), lineWidth: 1))
            }
        }
        .motionAnimation(.easeOut(duration: 0.25), value: env.location.isApproachingCamera)
    }

    private func statusCell(symbol: String, tint: Color,
                            title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.rounded(17, .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rounded(18, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.rounded(14, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Прибытие. Главное число — СКОЛЬКО ЕХАТЬ: это первый вопрос и водителя,
    /// и пассажира, и именно его Apple с Google держат героем. Время прибытия —
    /// рядом, вторым весом; ниже — остаток пути и камеры впереди по маршруту.
    private var etaCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatting.duration(env.route.remainingTime))
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    Image(systemName: "flag.checkered")
                        .font(.rounded(11, .bold))
                        .foregroundStyle(Theme.success)
                    Text(env.route.arrivalDate.formatted(date: .omitted, time: .shortened))
                        .font(.rounded(14, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                Text(Formatting.distance(env.route.remainingDistance))
                    .font(.rounded(14, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                if camerasAhead > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(camerasAhead)")
                            .font(.rounded(14, .semibold).monospacedDigit())
                    }
                    .foregroundStyle(Theme.Types.camera)
                }
            }
        }
        .frame(minWidth: 116, alignment: .leading)
    }

    /// Сколько камер маршрута ещё впереди (пройденные не считаем).
    private var camerasAhead: Int {
        let progress = env.route.progressAlong
        // count(where:) вместо filter().count: считается на каждый тик GPS, а
        // промежуточный массив камер маршрута тут не нужен никому.
        return env.route.camerasOnRoute.count { $0.distanceAlong > progress }
    }

    // MARK: - Верхние баннеры

    /// Алерт приближения: три СТУПЕНИ, различимые боковым зрением, а не только
    /// оттенком. Раньше уровни красились alertTint'ом, а role(.attention) и
    /// есть warning — лестница 1→3 схлопывалась в «янтарь, янтарь, красный».
    /// Теперь ступени различаются устройством плашки:
    ///   1 — тёмная плашка с янтарной кромкой («заметь»),
    ///   2 — янтарная заливка с тёмным текстом («готовься»),
    ///   3 — красная заливка, белый текст и пульс глифа («действуй»).
    private func approachBanner(camera: Camera, distance: CLLocationDistance) -> some View {
        let level = max(1, env.location.alertLevel)
        let fill: AnyShapeStyle = switch level {
        case 1:  AnyShapeStyle(Theme.background.opacity(0.88))
        case 2:  AnyShapeStyle(Theme.warning.gradient)
        default: AnyShapeStyle(Theme.danger.gradient)
        }
        let foreground: Color = switch level {
        case 1:  Theme.textPrimary
        case 2:  Theme.background
        default: .white
        }
        let glow: Color = level >= 3 ? Theme.danger : Theme.warning
        return HStack(spacing: 12) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(20, .bold))
                .foregroundStyle(level == 1 ? Theme.warning : foreground)
                .frame(width: 42, height: 42)
                .background((level == 1 ? Theme.warning : foreground).opacity(0.18),
                            in: Circle())
                .symbolEffect(.pulse, options: .repeating, isActive: level >= 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(28, .heavy).monospacedDigit())
                    .foregroundStyle(foreground)
                    // Не переносить и не сжимать: уступать место обязан манёвр
                    // (у него ellipsis), а не цифра, ради которой баннер
                    // существует.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                // shortName, а не displayName: тип нужен одним словом. Без
                // fixedSize: длинное слово честно обрезается многоточием внутри
                // плашки, а не вылезает из неё под системные кнопки.
                Text(camera.kind.shortName)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(foreground.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }

            if let limit = env.speedLimits.limit(near: camera.coordinate) {
                SpeedLimitSign(limit: limit, diameter: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 340, alignment: .trailing)
        .layoutPriority(1)
        .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(level == 1 ? Theme.warning : .clear, lineWidth: 2))
        .shadow(color: glow.opacity(level == 1 ? 0.35 : 0.55), radius: 16, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Манёвр: «через 300 м — направо на Амира Темура».
    ///
    /// Сама инструкция — первичный текст, дистанция — вторичный по цвету:
    /// водитель ищет глазами «куда», а не «сколько». Раньше было наоборот —
    /// имя улицы стояло самым мелким текстом баннера (12 pt), при том что
    /// у Google и Apple именно оно доминирует.
    private func maneuverBanner(step: RouteStep, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(24, .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 50, height: 50)
                .background(Theme.accent.gradient,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                Text(step.text)
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .layoutPriority(0)
        .background(Theme.background.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
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

    /// Полоска приближения: заполняется к камере и «греется» — боковым зрением
    /// читается быстрее цифр.
    private func approachBar(_ progress: Double) -> some View {
        let tint = Theme.role(progress > 0.66 ? .alarm : progress > 0.33 ? .attention : .neutral)
        return Capsule()
            .fill(Theme.stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(progress, 0.04), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(width: 120, height: 3)
            .padding(.top, 2)
            .motionAnimation(.easeOut(duration: 0.3), value: progress)
    }
}

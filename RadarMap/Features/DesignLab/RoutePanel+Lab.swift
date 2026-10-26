//
//  RoutePanel+Lab.swift
//  RadarMap
//
//  Этап 31: два варианта панели маршрута до старта (`-designRoute A|B`).
//
//  Было: стеклянная карточка над картой (днём белёсая, круги «поделиться» и
//  «по пути» бледно-голубые — читаются как выключенные), «2 камеры на
//  маршруте» в две строки по центру, а под карточкой — ещё и док главного
//  экрана: два слоя по 140 pt, карта маршрута зажата между ними и HUD.
//
//  A «Сплошная»     — та же раскладка на сплошной поверхности, док убран;
//                     камеры, «По пути», «Поделиться» — одним рядом чипов.
//  B «Время-герой»  — как у Яндекса: время крупно (30), под ним путь и
//                     прибытие; «Поехали» и рядом счётчик камер одной строкой.
//

import SwiftUI

extension RoutePanel {

    @ViewBuilder var labRouteCard: some View {
        switch DesignLab.route {
        case .b: labRouteB
        default: labRouteA
        }
    }

    private var labShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
    }

    private var labCloseButton: some View {
        Button { env.route.clear() } label: {
            Image(systemName: "xmark")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.background, in: Circle())
                .tapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Сбросить маршрут"))
    }

    private func labChip(_ icon: String, _ title: String? = nil, tint: Color = Theme.accent,
                         label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if CameraGlyph(symbol: icon) != nil {
                    SymbolIcon(icon, size: 13, weight: .bold).foregroundStyle(tint)
                } else {
                    Image(systemName: icon).font(.rounded(13, .semibold)).foregroundStyle(tint)
                }
                if let title {
                    Text(verbatim: title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, title == nil ? 0 : 14)
            .frame(minWidth: 44, minHeight: 40)
            .background(Theme.background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(label))
    }

    private var labCameraTint: Color {
        env.route.ourCameraCount == 0 ? Theme.success : Theme.Types.camera
    }

    @ViewBuilder private var labExtraChips: some View {
        if let onShowAlongRoute {
            labChip(AlongRouteText.symbol(env.settings.vehicleEnergy), String(localized: "По пути"),
                    label: "По пути: заправки, гостиницы, кафе", action: onShowAlongRoute)
        }
        if let onShareArrival, env.etaShare.isAvailable, !env.etaShare.isSharing {
            labChip("square.and.arrow.up", label: "Поделиться прибытием", action: onShareArrival)
        }
    }

    // MARK: A

    private var labRouteA: some View {
        let route = env.route
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.onAccentFill)
                    .frame(width: 36, height: 36)
                    .background(Theme.accentFill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.destinationName)
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(route.etaText) · \(route.distanceText)")
                            .foregroundStyle(Theme.textSecondary)
                        if let note = route.trafficNote {
                            Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                            Text(verbatim: note)
                                .foregroundStyle(Self.trafficTint(route.trafficDelay ?? 0))
                        }
                    }
                    .font(.rounded(12, .semibold))
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                labCloseButton
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    labChip(Icon.cameras, String(localized: "\(route.ourCameraCount) камер"),
                            tint: labCameraTint, label: "Камеры на маршруте", action: onShowCameras)
                        .disabled(route.camerasOnRoute.isEmpty)
                    labExtraChips
                }
            }
            .scrollIndicators(.hidden)
            PrimaryButton(title: "Поехали", systemImage: "play.fill", action: onTripToggle)
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: labShape)
        .overlay(labShape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    // MARK: B

    private var labRouteB: some View {
        let route = env.route
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(route.destinationName)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: route.etaText)
                        .font(.rounded(30, .heavy))
                        .foregroundStyle(route.trafficNote == nil ? Theme.textPrimary
                                         : Self.trafficTint(route.trafficDelay ?? 0))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: route.distanceText)
                        Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                        Image(systemName: "flag.checkered").font(.rounded(12, .semibold))
                        Text(route.arrivalDate, style: .time)
                        if let note = route.trafficNote {
                            Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                            Text(verbatim: note).foregroundStyle(Self.trafficTint(route.trafficDelay ?? 0))
                        }
                    }
                    .font(.rounded(12, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                labCloseButton
            }
            HStack(spacing: 8) {
                PrimaryButton(title: "Поехали", systemImage: "play.fill", action: onTripToggle)
                Button(action: onShowCameras) {
                    VStack(spacing: 0) {
                        SymbolIcon(Icon.cameras, size: 13, weight: .bold)
                            .foregroundStyle(labCameraTint)
                        Text(verbatim: "\(route.ourCameraCount)")
                            .font(.rounded(15, .heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 56, height: 54)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(route.camerasOnRoute.isEmpty)
                .accessibilityLabel(Text("Камеры на маршруте"))
                Menu {
                    if let onShowAlongRoute {
                        Button(action: onShowAlongRoute) {
                            Label("По пути", systemImage: AlongRouteText.symbol(env.settings.vehicleEnergy))
                        }
                    }
                    if let onShareArrival, env.etaShare.isAvailable, !env.etaShare.isSharing {
                        Button(action: onShareArrival) {
                            Label("Поделиться прибытием", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 48, height: 54)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
                .accessibilityLabel(Text("Ещё"))
            }
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: labShape)
        .overlay(labShape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }
}

//
//  AlertSampleView.swift
//  RadarMap
//
//  Пример оповещения: экран камеры из поездки (`ApproachAlertView`) на
//  выдуманной камере, сигнал и фраза — через AlertPlayer на громкости из
//  настроек. Закрывается касанием или сам через `alertSampleSeconds`.
//

import SwiftUI

struct AlertSampleView: View {
    @Environment(AppEnvironment.self) private var env
    let onClose: () -> Void

    private var allowed: Bool {
        AlertSample.canShow(isTripActive: env.location.isTripActive,
                            isApproachingCamera: env.location.isApproachingCamera)
    }

    var body: some View {
        ApproachAlertView(camera: AlertSample.camera,
                          distance: AlertSample.meters,
                          speedKmh: AlertSample.speedKmh,
                          relativeBearing: AlertSample.relativeBearing,
                          alertRadius: AlertSample.alertRadius,
                          layout: .fullScreen,
                          isSample: true,
                          onDismiss: onClose)
            .environment(\.colorScheme, .dark)
            .task {
                guard allowed else { return onClose() }
                env.alerts.playSample()
                #if DEBUG
                // На снимок (`-alertSample`) пример не закрывается сам.
                if ProcessInfo.processInfo.arguments.contains("-alertSample") { return }
                #endif
                do {
                    try await Task.sleep(for: .seconds(AppConfig.alertSampleSeconds))
                } catch {
                    return   // закрыли раньше — задача отменена вместе с экраном
                }
                onClose()
            }
            // Поездка началась или подошла настоящая камера — пример уступает.
            .onChange(of: allowed) { _, now in
                if !now { onClose() }
            }
    }
}

extension View {
    /// Полноэкранный пример оповещения поверх текущего экрана.
    func alertSample(isPresented: Binding<Bool>) -> some View {
        fullScreenCover(isPresented: isPresented) {
            AlertSampleView { isPresented.wrappedValue = false }
        }
    }
}

/// Строка «Показать, как выглядит оповещение» — в поездке и при настоящем
/// оповещении недоступна.
struct AlertSampleButton: View {
    @Environment(AppEnvironment.self) private var env
    /// DEBUG `-alertSample` (вместе с `-settingsPage alerts`) — пример открыт сразу, на снимок.
    @State private var shown = Self.openedAtLaunch

    private static var openedAtLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-alertSample")
        #else
        false
        #endif
    }

    var body: some View {
        let allowed = AlertSample.canShow(isTripActive: env.location.isTripActive,
                                          isApproachingCamera: env.location.isApproachingCamera)
        Button {
            shown = true
        } label: {
            Label("Показать, как выглядит оповещение", systemImage: "play.rectangle.fill")
        }
        .disabled(!allowed)
        .alertSample(isPresented: $shown)
    }
}

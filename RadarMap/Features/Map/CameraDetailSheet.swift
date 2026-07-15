//
//  CameraDetailSheet.swift
//  RadarMap
//
//  Попап камеры: тип, адрес, нарушения, кнопка «Открыть в Картах».
//

import SwiftUI
import MapKit
import UIKit

struct CameraDetailSheet: View {
    let camera: Camera
    var onRoute: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum ReportState: Equatable { case idle, sending, sent, failed }
    @State private var reportState: ReportState = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if camera.isApproximate { approximateBanner }
                    addressBlock
                    violationsBlock
                    routeButton
                    openInMapsButton
                    actionsBlock
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle("Камера №\(camera.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Секции

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(20, .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(camera.kind.tint.gradient, in: Circle())
                .shadow(color: camera.kind.tint.opacity(0.6), radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.kind.displayName)
                    .font(.rounded(18, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let coordinate = env.location.currentCoordinate {
                    Text("в \(Formatting.distance(camera.distance(from: coordinate))) от вас")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !camera.location.isEmpty {
                Text(camera.location)
                    .font(.rounded(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            Label(camera.subtitle, systemImage: "mappin.and.ellipse")
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
            Text(String(format: "%.6f, %.6f", camera.lat, camera.lon))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
        }
    }

    private var violationsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Фиксирует нарушения")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(camera.violations, id: \.self) { violation in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.rounded(13))
                        .foregroundStyle(camera.kind.tint)
                        .padding(.top, 2)
                    Text(violation.capitalizedFirst)
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    private var approximateBanner: some View {
        Label("Координаты приблизительные — в исходных данных они были повреждены.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.rounded(13))
            .foregroundStyle(Theme.radar)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.radar.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    @ViewBuilder private var routeButton: some View {
        if let onRoute {
            PrimaryButton(title: "Маршрут сюда", systemImage: "arrow.triangle.turn.up.right.circle.fill") {
                dismiss()
                onRoute()
            }
        }
    }

    private var openInMapsButton: some View {
        PrimaryButton(title: "Открыть в Картах", systemImage: "map.fill") {
            let item = MKMapItem(location: CLLocation(latitude: camera.lat, longitude: camera.lon),
                                 address: nil)
            item.name = camera.displayTitle
            item.openInMaps()
        }
    }

    @ViewBuilder private var actionsBlock: some View {
        if env.mobile.isMobile(camera) {
            // Краудсорсинг: подтверждение продлевает жизнь отметки, «нет радара» — гасит.
            HStack(spacing: 12) {
                Button {
                    Task { await env.mobile.vote(cameraID: camera.id, stillThere: true) }
                    dismiss()
                } label: {
                    Label("Радар на месте", systemImage: "hand.thumbsup.fill")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.success)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
                Button {
                    Task { await env.mobile.vote(cameraID: camera.id, stillThere: false) }
                    dismiss()
                } label: {
                    Label("Уже нет", systemImage: "hand.thumbsdown.fill")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
            }
        } else if env.cameras.isCustom(camera) {
            destructiveButton(title: "Удалить камеру", icon: "trash") {
                env.cameras.deleteCustom(camera)   // revision → MapScreen обновит карту и мониторинг
                dismiss()
            }
        } else {
            reportBlock
        }
    }

    // MARK: - Репорт об ошибке в базе

    /// Обратная связь по камере: репорт уходит на сервер (ручная модерация),
    /// «камеры больше нет» дополнительно скрывает её локально сразу.
    @ViewBuilder private var reportBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что-то не так с этой камерой?")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)

            switch reportState {
            case .sent:
                Label("Спасибо! Проверим и обновим базу.", systemImage: "checkmark.circle.fill")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.success.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .sending:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Отправляем…")
                        .font(.rounded(14, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            case .idle, .failed:
                HStack(spacing: 10) {
                    reportButton(title: "Камеры больше нет", icon: "camera.slash.fill") {
                        sendReport(.gone)
                    }
                    reportButton(title: "Неверное место", icon: "mappin.slash.circle.fill") {
                        sendReport(.wrongLocation)
                    }
                }
                if reportState == .failed {
                    Label("Не удалось отправить — проверьте сеть.", systemImage: "wifi.slash")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.danger)
                }
                Button {
                    env.cameras.hide(camera)
                    dismiss()
                } label: {
                    Label("Просто скрыть на моей карте", systemImage: "eye.slash")
                        .font(.rounded(13, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: reportState)
    }

    private func reportButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.rounded(17, .semibold))
                Text(title).font(.rounded(13, .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.radar)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.radar.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }

    private func sendReport(_ reason: CameraReportReason) {
        reportState = .sending
        Task {
            let ok = await env.feedback.reportCamera(camera, reason: reason,
                                                     dbVersion: env.cameras.dbVersion)
            guard ok else {
                reportState = .failed
                return
            }
            reportState = .sent
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if reason == .gone {
                env.cameras.hide(camera)   // убрали у себя сразу, база поправится после модерации
            }
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        }
    }

    private func destructiveButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

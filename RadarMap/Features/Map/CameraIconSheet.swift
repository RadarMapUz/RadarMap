//
//  CameraIconSheet.swift
//  RadarMap
//
//  DEBUG-лист значков камер (29.C, `-dumpCameraIcons <папка>`): все типы в
//  обликах карты (CameraMarkerLook.rasters — те же растры, что в движке) и
//  в размерах экранов (CameraIcon). Проверка глазами одного источника.
//

#if DEBUG
import SwiftUI

struct CameraIconSheet: View {
    /// Значок на тип: все камеры — один (29.C2), пост ДПС, ДТП, «прочее».
    private let kinds: [CameraType] = [.stationaryCamera, .dpsPost, .accident, .other("")]
    private let day = Theme.Scene.mapDay
    private let night = Theme.Scene.mapNight
    /// Тёмный асфальт поездки (29.B) — на нём значок тоже должен читаться.
    private let asphalt = Theme.Scene.roadDark

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                HStack(spacing: 0) {
                    Text(verbatim: kind.glyph == .camera ? "Камера (все типы)" : kind.displayName).font(.system(size: 13, weight: .medium))
                        .frame(width: 210, alignment: .leading).padding(.leading, 12)
                    ForEach(Array(CameraMarkerLook.rasters.enumerated()), id: \.offset) { _, look in
                        cell(look.suffix == "-calm-n" ? night : day) {
                            Image(uiImage: CameraIconArt.marker(kind.glyph, look: look))
                        }
                    }
                    cell(asphalt) { Image(uiImage: CameraIconArt.marker(kind.glyph, look: CameraMarkerLook.rasters[0])) }
                    cell(asphalt) { Image(uiImage: CameraIconArt.marker(kind.glyph, look: CameraMarkerLook.rasters[2])) }
                    cell(.white, width: 300) {
                        HStack(spacing: 12) {
                            ForEach([72.0, 46, 38, 34, 24], id: \.self) { side in
                                CameraIcon(kind: kind, side: side)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func cell(_ background: Color, width: CGFloat = 70, @ViewBuilder _ content: () -> some View) -> some View {
        content().frame(width: width, height: 80).background(background)
    }
}
#endif

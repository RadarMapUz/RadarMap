//
//  RadarMapWidgetsBundle.swift
//  RadarMapWidgets
//

import WidgetKit
import SwiftUI

@main
struct RadarMapWidgetsBundle: WidgetBundle {
    init() {
        // До первой строки текста: `Bundle` запоминает язык один раз.
        WidgetPrefs.applyLanguage(WidgetPrefs.read()?.language)
    }

    var body: some Widget {
        RadarStatsWidget()
        RadarWeekWidget()
        RadarCommuteWidget()
        CameraActivityWidget()
        StartTripControl()
        RadarReportControl()
        SoundControl()
        GoHomeControl()
        GoWorkControl()
    }
}

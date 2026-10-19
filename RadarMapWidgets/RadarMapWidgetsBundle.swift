//
//  RadarMapWidgetsBundle.swift
//  RadarMapWidgets
//

import WidgetKit
import SwiftUI

@main
struct RadarMapWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RadarStatsWidget()
        RadarWeekWidget()
        CameraActivityWidget()
        StartTripControl()
    }
}

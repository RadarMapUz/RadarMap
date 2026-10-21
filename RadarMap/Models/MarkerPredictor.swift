//
//  MarkerPredictor.swift
//  RadarMap
//
//  Где значок «я» СЕЙЧАС, а не где был последний фикс. Только картинка.
//

import Foundation

#if DEBUG
/// Замер лага значка (25.B): `-logMarker` пишет в журнал фиксы и нарисованную
/// точку, разбор — `tools/marker_lag.py`.
nonisolated enum MarkerLagLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-logMarker")
}
#endif

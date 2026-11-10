#!/bin/zsh
# Копирует настоящие исходники виджетов в src/ и открывает их для стенда.
# Репозиторий не меняется. Подстановки только такие: private → internal
# у типов, и семейство виджета берётся из StandEnv вместо окружения WidgetKit.
WT=/Users/zafarbekpolvonboev/Zafar/RadarMap-wt/72
SRC=${1:?куда}
rm -rf $SRC; mkdir -p $SRC
cp $WT/RadarMapWidgets/{RadarStatsWidget,RadarWeekWidget,RadarCommuteWidget,CameraActivityWidget}.swift $SRC/
cp $WT/RadarWatchWidgets/NextCameraComplication.swift $SRC/
cp $WT/Shared/{ActivityIntents,CameraActivityAttributes,CameraGlyph,NumberFormat,SharedDefaults,SpokenUnits,TripLink,WatchComplication,WidgetCommute,WidgetPalette}.swift $SRC/
cd $SRC
sed -i '' -E 's/^private (struct|enum|func) /\1 /' *.swift
sed -i '' -E 's/@Environment\(\\\.widgetFamily\) private var family/private var family: WidgetFamily { StandEnv.family }/' *.swift
sed -i '' -E 's/@Environment\(\\\.activityFamily\) private var family/private var family: ActivityFamily { StandEnv.activityFamily }/' *.swift
sed -i '' -E 's/    private func typeIcon/    func typeIcon/' CameraActivityWidget.swift
# Угловая компликация есть только в watchOS.
sed -i '' -E '/case \.accessoryCorner: corner/d; s/\.accessoryCorner, //' NextCameraComplication.swift
sed -i '' -E '/^#Preview/,$d' NextCameraComplication.swift

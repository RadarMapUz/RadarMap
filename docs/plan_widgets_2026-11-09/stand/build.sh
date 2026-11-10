#!/bin/zsh
# zsh build.sh <рабочая папка> <UDID симулятора> <папка снимков> [ru|uz] [mock]
HERE=${0:A:h}; WORK=${1:?}; U=${2:?}; OUT=${3:?}; L=${4:-ru}
ISDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
zsh $HERE/prep.sh $WORK/src
mkdir -p $WORK/bin
xcrun xcstringstool compile $HERE/../../../Shared/Localizable.xcstrings --output-directory $WORK/bin
nice -n 15 swiftc -target arm64-apple-ios26.0-simulator -sdk "$ISDK" -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  -module-name Stand -o $WORK/bin/stand $WORK/src/*.swift $HERE/{lib,data,mock,main}.swift
xcrun simctl spawn $U $WORK/bin/stand $OUT $L $5 -AppleLanguages "($L)" -AppleLocale ${L}_UZ

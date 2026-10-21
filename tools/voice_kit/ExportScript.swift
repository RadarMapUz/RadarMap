//
//  ExportScript.swift
//  tools/voice_kit
//
//  Точка входа экспорта сценария: собирается вместе с VoiceEvent.swift,
//  VoiceComposer.swift и VoiceScript.swift (см. export_script.sh) и печатает
//  CSV для диктора. Список отрывков выводится из кода приложения, поэтому
//  руками сценарий не правится — только этим экспортом.
//

import Foundation

@main
struct ExportScript {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        let language = arguments.first.flatMap(VoiceLanguage.init(rawValue:)) ?? .uz
        print(VoiceScript.csv(language), terminator: "")
    }
}

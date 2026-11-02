//
//  FamilyKeys.swift
//  RadarMap
//
//  Ключи записи семейных ссылок — в связке ключей, а не в UserDefaults
//  (аудит 38B, L-9): кто достал файл настроек из резервной копии, тот мог
//  писать в ссылку мамы «дома». В файле остаются имя, режим и адрес.
//
//  Главное правило — ключ не теряется НИКОГДА: потерянный ключ значит
//  мёртвую ссылку у близкого, которую водитель заметит только когда мама
//  перестанет видеть «в пути». Поэтому:
//    • из файла ключ убирается только после того, как связка его приняла;
//    • связка не приняла — ключ остаётся в файле, как до этой версии;
//    • ключ в файле новее связки (сбой при прошлой записи) и побеждает;
//    • связка не отдала ключ — он не стирается ни там, ни тут: ссылка ждёт,
//      а писать в неё до тех пор нечем (`FamilyRecipient.isKeyLocked`).
//

import Foundation
import os

nonisolated enum FamilyKeys {

    struct Loaded: Equatable {
        /// Круг в памяти: у каждого, чей ключ нашёлся, — сам ключ.
        var circle: FamilyCircle
        /// Что точно лежит в связке: id → ключ. Повторно не пишем.
        var known: [UUID: String]
        /// Файл надо переписать: ключи из него ушли в связку (миграция).
        var needsResave: Bool
    }

    /// Круг, прочитанный с диска, → круг в памяти. Ключи из файла (сборка до
    /// этой или прошлый сбой связки) переносятся в связку; ключи из связки
    /// возвращаются в память.
    static func restored(_ disk: FamilyCircle, from store: any SecretStore) -> Loaded {
        var circle = disk
        var known: [UUID: String] = [:]
        var needsResave = false
        for index in circle.recipients.indices {
            let id = circle.recipients[index].id
            if let key = circle.recipients[index].key {
                do {
                    try store.write(key, account: id.uuidString)
                    known[id] = key
                    needsResave = true
                } catch {
                    Log.app.error("близкие: связка ключей не приняла ключ — остаётся в файле (\(String(describing: error), privacy: .public))")
                }
            } else if circle.recipients[index].keyInKeychain == true {
                do {
                    if let key = try store.read(account: id.uuidString) {
                        circle.recipients[index].key = key
                        known[id] = key
                    } else {
                        Log.app.error("близкие: ключа нет в связке — ссылку надо сменить")
                    }
                } catch {
                    Log.app.error("близкие: связка ключей недоступна (\(String(describing: error), privacy: .public))")
                }
            }
        }
        return Loaded(circle: circle, known: known, needsResave: needsResave)
    }

    /// Круг в памяти → что писать в файл. Ключ уходит из файла, только если
    /// связка его приняла; ключи тех, кого в круге больше нет, из связки
    /// стираются (их ссылки уже погашены `revoke`).
    static func persisted(_ circle: FamilyCircle, in store: any SecretStore,
                          known: inout [UUID: String]) -> FamilyCircle {
        var disk = circle
        for index in disk.recipients.indices {
            let recipient = disk.recipients[index]
            // Ссылка до 14.12 (ключа нет вовсе) или ключ ещё в связке и не
            // отдан — пишем как есть: флаг сохраняет «ключ там».
            guard let key = recipient.key else { continue }
            if known[recipient.id] != key {
                do {
                    try store.write(key, account: recipient.id.uuidString)
                    known[recipient.id] = key
                } catch {
                    Log.app.error("близкие: связка ключей не приняла ключ — пишу в файл (\(String(describing: error), privacy: .public))")
                    disk.recipients[index].keyInKeychain = nil
                    continue
                }
            }
            disk.recipients[index].key = nil
            disk.recipients[index].keyInKeychain = true
        }
        let present = Set(circle.recipients.map(\.id))
        for id in known.keys where !present.contains(id) {
            do {
                try store.delete(account: id.uuidString)
                known[id] = nil
            } catch {
                // Осиротевший ключ погашенной ссылки — не утечка смысла:
                // пишет он в ссылку, которую сервер уже закрыл. Повторим при
                // следующей записи.
                Log.app.error("близкие: ключ убранного близкого не стёрт (\(String(describing: error), privacy: .public))")
            }
        }
        return disk
    }
}

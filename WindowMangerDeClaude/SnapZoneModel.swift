import Foundation
import CoreGraphics

// MARK: - Snap Layout Model
//
// Diese Datei ist bewusst frei von AppKit: sie enthaelt ausschliesslich die
// Geometrie- und Persistenzlogik der Snap-Zonen und laesst sich dadurch mit
//
//     swiftc -o /tmp/snapzonetests SnapZoneModel.swift ../Tests/SnapZoneModelTests.swift
//
// eigenstaendig uebersetzen und testen - das restliche Programm haengt an
// AppKit und einer laufenden App und ist so nicht pruefbar.

/// Eine einzelne Zone innerhalb einer Aufteilung.
///
/// `previewRect` ist ein Einheitsrechteck (0...1) mit dem Ursprung UNTEN LINKS -
/// dieselbe Konvention wie `NSScreen.visibleFrame`, dadurch ist `compute` eine
/// reine Skalierung ohne Achsenspiegelung.
struct SnapLayout {
    let title: String
    let previewRect: CGRect
    /// Zu welcher Aufteilung die Zone gehoert. Titel allein taugen nicht als
    /// Identitaet, sobald der Nutzer dieselbe Form in mehreren Slots ablegen darf.
    /// -1 bedeutet "gehoert zu keiner Aufteilung" (Ad-hoc-Layouts, etwa beim Drop
    /// auf eine freie Restflaeche).
    let groupID: Int
    let compute: (CGRect) -> CGRect

    init(title: String, previewRect: CGRect, groupID: Int = -1, compute: @escaping (CGRect) -> CGRect) {
        self.title = title
        self.previewRect = previewRect
        self.groupID = groupID
        self.compute = compute
    }

    /// Fuellt die Zone den ganzen Bildschirm? Wird ueber die Geometrie bestimmt und
    /// nicht mehr ueber den Titel - der ist seit den konfigurierbaren Zonen
    /// generiert und darf sich aendern, ohne Verhalten zu veraendern.
    var isFullscreen: Bool {
        abs(previewRect.width - 1) < 0.001 && abs(previewRect.height - 1) < 0.001
    }
}

/// Eine komplette Bildschirmaufteilung - im Panel eine Kachel, in den
/// Einstellungen ein "Slot".
struct SnapGroup {
    let id: Int
    let zones: [SnapLayout]
}

// MARK: - Bausteine

/// Die Formen, aus denen der Nutzer eine Aufteilung zusammensetzt.
///
/// Alle Breiten sind in Zwoelfteln des Bildschirms angegeben: 12, 8, 6 und 4
/// lassen sich exakt addieren, waehrend `2.0/3.0 + 1.0/3.0` in Gleitkomma nicht
/// zuverlaessig 1,0 ergibt. Die Blockade-Regel muss exakt sein, deshalb ganzzahlig.
enum ZoneBlock: String, Codable, CaseIterable {
    case full        // 1/1 - ganzer Bildschirm
    case twoThirds   // 2/3 der Breite, volle Hoehe
    case half        // 1/2 der Breite, volle Hoehe
    case third       // 1/3 der Breite, volle Hoehe
    case quarter     // 1/2 der Breite x 1/2 der Hoehe

    /// Breite in Zwoelfteln des Bildschirms.
    var widthTwelfths: Int {
        switch self {
        case .full: return 12
        case .twoThirds: return 8
        case .half: return 6
        case .third: return 4
        case .quarter: return 6
        }
    }

    /// Nur das Viertel ist halbhoch; alle uebrigen Bausteine reichen vom oberen
    /// zum unteren Bildschirmrand.
    var isHalfHeight: Bool { self == .quarter }

    /// Kurzform fuer generierte Zonentitel ("½", "⅔", ...). Beim Vollbild leer,
    /// weil dessen Titel keinen Zusatz traegt.
    var fractionGlyph: String {
        switch self {
        case .full: return ""
        case .twoThirds: return "⅔"
        case .half: return "½"
        case .third: return "⅓"
        case .quarter: return "¼"
        }
    }
}

/// Ein platzierter Baustein: die Form plus die Flaeche, die sie im Einheits-
/// bildschirm belegt.
struct PlacedBlock: Equatable {
    let block: ZoneBlock
    /// Einheitsrechteck (0...1), Ursprung unten links.
    let rect: CGRect
    /// Generierter, menschenlesbarer Titel ("← ½", "↘ ¼", "Vollbild").
    let title: String
}

// MARK: - Packen und Blockade-Regel

/// Setzt eine Folge von Bausteinen zu einer Bildschirmaufteilung zusammen.
///
/// Regeln (spaltenweise von links nach rechts):
/// * Ein vollhoher Baustein belegt eine eigene Spalte seiner Breite ueber die
///   ganze Hoehe; der Schreibkopf rueckt um diese Breite nach rechts.
/// * Das erste Viertel oeffnet eine halbbreite Spalte und belegt darin die OBERE
///   Haelfte; der Schreibkopf rueckt um eine halbe Breite nach rechts. Das
///   naechste Viertel fuellt die untere Haelfte dieser offenen Spalte, ohne den
///   Schreibkopf zu bewegen. Eine offene Spalte bleibt beliebig lange nutzbar -
///   spaeter platzierte Bausteine liegen stets rechts davon und koennen die
///   freie untere Haelfte nicht ueberdecken.
/// * `full` passt nur in einen komplett leeren Slot.
/// * Wuerde der Schreibkopf ueber 12/12 hinauslaufen, passt der Baustein nicht -
///   genau das ist die in der Spezifikation geforderte automatische Blockade.
enum SnapSlotPacker {
    private struct PackState {
        var cursor = 0
        var openQuarterColumn: Int?
        var blockCount = 0

        mutating func append(_ block: ZoneBlock) -> CGRect? {
            if block == .full {
                guard blockCount == 0 else { return nil }
                cursor = 12
                blockCount += 1
                return CGRect(x: 0, y: 0, width: 1, height: 1)
            }

            if block.isHalfHeight, let column = openQuarterColumn {
                openQuarterColumn = nil
                blockCount += 1
                return CGRect(x: Double(column) / 12.0, y: 0,
                              width: Double(block.widthTwelfths) / 12.0, height: 0.5)
            }

            guard cursor + block.widthTwelfths <= 12 else { return nil }
            let x = cursor
            cursor += block.widthTwelfths
            blockCount += 1

            if block.isHalfHeight {
                openQuarterColumn = x
                return CGRect(x: Double(x) / 12.0, y: 0.5,
                              width: Double(block.widthTwelfths) / 12.0, height: 0.5)
            }

            return CGRect(x: Double(x) / 12.0, y: 0,
                          width: Double(block.widthTwelfths) / 12.0, height: 1)
        }
    }

    /// Platziert alle Bausteine. `nil`, sobald einer davon nicht mehr passt.
    static func pack(_ blocks: [ZoneBlock]) -> [PlacedBlock]? {
        var state = PackState()
        var placed: [PlacedBlock] = []
        placed.reserveCapacity(blocks.count)

        for block in blocks {
            guard let rect = state.append(block) else { return nil }
            placed.append(PlacedBlock(block: block, rect: rect,
                                      title: title(for: block, at: rect)))
        }
        return placed
    }

    /// Darf `block` an `blocks` angehaengt werden? Aequivalent zu
    /// `pack(blocks + [block]) != nil`, aber ohne die Titel zu bauen.
    static func canAppend(_ block: ZoneBlock, to blocks: [ZoneBlock]) -> Bool {
        var state = PackState()
        for existing in blocks where state.append(existing) == nil { return false }
        return state.append(block) != nil
    }

    /// Wie viele Zwoelftel Breite rechts noch frei sind. Rein informativ fuer die
    /// UI (Fortschrittsbalken/Restflaeche) - die Blockade selbst laeuft ueber
    /// `canAppend`, weil eine offene Viertel-Spalte Platz bietet, den diese Zahl
    /// nicht abbildet.
    static func freeWidthTwelfths(_ blocks: [ZoneBlock]) -> Int {
        var state = PackState()
        for block in blocks {
            guard state.append(block) != nil else { return 0 }
        }
        return 12 - state.cursor
    }

    /// Der generierte Titel eines platzierten Bausteins.
    ///
    /// Vollbild heisst schlicht "Vollbild". Sonst steht vorn ein Richtungspfeil,
    /// dahinter die Bruch-Kurzform:
    /// * vollhoch: "←" am linken Rand, "→" am rechten Rand, sonst "↔"
    /// * Viertel: "↖ ↗ ↙ ↘" an den Ecken, "↑"/"↓" wenn es weder links noch rechts anliegt
    static func title(for block: ZoneBlock, at rect: CGRect) -> String {
        guard block != .full else { return "Vollbild" }

        let epsilon = 0.001
        let isLeft = abs(rect.minX) < epsilon
        let isRight = abs(rect.maxX - 1) < epsilon
        let arrow: String

        if block.isHalfHeight {
            let isTop = abs(rect.maxY - 1) < epsilon
            switch (isLeft, isRight, isTop) {
            case (true, _, true): arrow = "↖"
            case (_, true, true): arrow = "↗"
            case (true, _, false): arrow = "↙"
            case (_, true, false): arrow = "↘"
            case (_, _, true): arrow = "↑"
            case (_, _, false): arrow = "↓"
            }
        } else if isLeft {
            arrow = "←"
        } else if isRight {
            arrow = "→"
        } else {
            arrow = "↔"
        }

        return "\(arrow) \(block.fractionGlyph)"
    }
}

// MARK: - Werkseinstellung

enum SnapZoneDefaults {
    /// Fuenf konfigurierbare Slots - so viele Kacheln zeigt das Panel maximal.
    static let slotCount = 5
    /// Mehr eigene Anordnungen sollen es laut Spezifikation nicht werden.
    static let maxProfiles = 3

    /// Die werksseitigen fuenf Aufteilungen. Erzeugen ueber `SnapSlotPacker.pack`
    /// exakt die Geometrie, die das Panel vor dem Konfigurator hatte.
    static let factorySlots: [[ZoneBlock]] = [
        [.full],
        [.half, .half],
        [.twoThirds, .third],
        [.half, .quarter, .quarter],
        [.quarter, .quarter, .quarter, .quarter],
    ]
}

/// Eine benannte, komplette Panel-Konfiguration.
struct SnapProfile: Codable, Equatable {
    var name: String
    /// Immer genau `SnapZoneDefaults.slotCount` Eintraege; leere Slots sind erlaubt.
    var slots: [[ZoneBlock]]
}

// MARK: - Persistenz

extension Notification.Name {
    /// Die aktive Zonen-Konfiguration hat sich geaendert - das Panel baut sich neu auf.
    static let snapZonesDidChange = Notification.Name("snapZonesDidChange")
}

/// Haelt die aktive Konfiguration und die gespeicherten Profile in den
/// UserDefaults und liefert daraus die `SnapGroup`s fuers Panel.
///
/// Der Initializer nimmt die `UserDefaults` entgegen, damit Tests gegen eine
/// eigene Suite laufen koennen statt gegen die echten Einstellungen des Nutzers.
final class SnapZoneStore {
    static let shared = SnapZoneStore(defaults: .standard)

    static let slotsKey = "snapZoneSlots"
    static let profilesKey = "snapZoneProfiles"

    private let defaults: UserDefaults
    private var storedSlots: [[ZoneBlock]]
    private var storedProfiles: [SnapProfile]
    private var groupsCache: [SnapGroup]?

    init(defaults: UserDefaults) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.slotsKey),
           let decoded = try? JSONDecoder().decode([[ZoneBlock]].self, from: data) {
            storedSlots = Self.normalizedSlots(decoded)
        } else {
            storedSlots = SnapZoneDefaults.factorySlots
        }

        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([SnapProfile].self, from: data) {
            storedProfiles = Array(decoded.prefix(SnapZoneDefaults.maxProfiles)).map {
                SnapProfile(name: $0.name, slots: Self.normalizedSlots($0.slots))
            }
        } else {
            storedProfiles = []
        }
        groupsCache = nil
    }

    private static func normalizedSlots(_ input: [[ZoneBlock]]) -> [[ZoneBlock]] {
        var result = Array(input.prefix(SnapZoneDefaults.slotCount))
        if result.count < SnapZoneDefaults.slotCount {
            result.append(contentsOf: repeatElement([], count: SnapZoneDefaults.slotCount - result.count))
        }

        return result.map { slot in
            var prefix: [ZoneBlock] = []
            for block in slot {
                guard SnapSlotPacker.canAppend(block, to: prefix) else { break }
                prefix.append(block)
            }
            return prefix
        }
    }

    /// Die aktive Konfiguration. Setzen persistiert, verwirft den Gruppen-Cache
    /// und verschickt `.snapZonesDidChange`.
    ///
    /// Beim Setzen wird auf genau `slotCount` Eintraege normalisiert (fehlende
    /// werden als leere Slots ergaenzt, ueberzaehlige abgeschnitten) und jeder
    /// Slot auf Packbarkeit geprueft: ein nicht packbarer Slot wird auf das
    /// laengste packbare Praefix gekuerzt, statt die App mit kaputter Geometrie
    /// laufen zu lassen.
    var slots: [[ZoneBlock]] {
        get { storedSlots }
        set {
            storedSlots = Self.normalizedSlots(newValue)
            if let data = try? JSONEncoder().encode(storedSlots) {
                defaults.set(data, forKey: Self.slotsKey)
            }
            groupsCache = nil
            NotificationCenter.default.post(name: .snapZonesDidChange, object: nil)
        }
    }

    /// Die gespeicherten Anordnungen, in Anlagereihenfolge.
    private(set) var profiles: [SnapProfile] {
        get { storedProfiles }
        set {
            storedProfiles = newValue
            if let data = try? JSONEncoder().encode(storedProfiles) {
                defaults.set(data, forKey: Self.profilesKey)
            }
        }
    }

    /// Sichert die aktive Konfiguration unter `name`.
    ///
    /// Ein bereits vorhandener Name wird ueberschrieben (an Ort und Stelle, die
    /// Reihenfolge bleibt). Ein neuer Name wird abgelehnt, sobald bereits
    /// `maxProfiles` Profile bestehen; Rueckgabe `false`. Ein Name, der nach
    /// Trimmen leer ist, wird ebenfalls abgelehnt.
    @discardableResult
    func saveProfile(named name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        if let index = profiles.firstIndex(where: { $0.name == trimmedName }) {
            var updated = profiles
            updated[index] = SnapProfile(name: trimmedName, slots: slots)
            profiles = updated
            return true
        }

        guard profiles.count < SnapZoneDefaults.maxProfiles else { return false }
        profiles = profiles + [SnapProfile(name: trimmedName, slots: slots)]
        return true
    }

    /// Entfernt das Profil. Unbekannte Namen sind kein Fehler.
    func deleteProfile(named name: String) {
        let remaining = profiles.filter { $0.name != name }
        guard remaining.count != profiles.count else { return }
        profiles = remaining
    }

    /// Uebernimmt ein gespeichertes Profil als aktive Konfiguration.
    /// `false`, wenn es den Namen nicht gibt.
    @discardableResult
    func applyProfile(named name: String) -> Bool {
        guard let profile = profiles.first(where: { $0.name == name }) else { return false }
        slots = profile.slots
        return true
    }

    /// "Standard wiederherstellen": setzt die aktive Konfiguration auf
    /// `factorySlots`. Gespeicherte Profile bleiben unangetastet.
    func resetToFactory() {
        slots = SnapZoneDefaults.factorySlots
    }

    /// Die aktive Konfiguration als Panel-Aufteilungen.
    ///
    /// Leere Slots erscheinen NICHT im Panel - es zeigt also zwischen einer und
    /// fuenf Kacheln. `SnapGroup.id` ist der Index des Slots in `slots` und bleibt
    /// dadurch stabil, auch wenn davor ein Slot leer ist; daran haengen
    /// Zonenfarbe und Restflaechen-Berechnung.
    var groups: [SnapGroup] {
        if let groupsCache { return groupsCache }

        let result = slots.enumerated().compactMap { slotIndex, blocks -> SnapGroup? in
            guard !blocks.isEmpty, let placed = SnapSlotPacker.pack(blocks) else { return nil }
            let zones = placed.map { placedBlock in
                let unitRect = placedBlock.rect
                return SnapLayout(title: placedBlock.title, previewRect: unitRect,
                                  groupID: slotIndex) { screen in
                    CGRect(x: screen.minX + unitRect.minX * screen.width,
                           y: screen.minY + unitRect.minY * screen.height,
                           width: unitRect.width * screen.width,
                           height: unitRect.height * screen.height)
                }
            }
            return SnapGroup(id: slotIndex, zones: zones)
        }
        groupsCache = result
        return result
    }
}

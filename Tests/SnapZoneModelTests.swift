import Foundation
import CoreGraphics

// Eigenstaendiger Testlauf ohne XCTest - das Projekt hat nur ein App-Target,
// ein Test-Target waere hier mehr Geruest als Nutzen.
//
//   swiftc -o /tmp/snapzonetests WindowMangerDeClaude/SnapZoneModel.swift Tests/SnapZoneModelTests.swift
//   /tmp/snapzonetests
//
// Beendet sich mit Status 1, sobald eine Pruefung fehlschlaegt.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (\(line)): \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL (\(line)): \(message)\n  erwartet: \(expected)\n  bekommen: \(actual)")
    }
}

/// Einheitsrechteck kurz notiert.
func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

func rectsAlmostEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    let e = 0.0005
    return abs(a.minX - b.minX) < e && abs(a.minY - b.minY) < e
        && abs(a.width - b.width) < e && abs(a.height - b.height) < e
}

func checkRects(_ blocks: [ZoneBlock], _ expected: [CGRect], _ message: String, line: UInt = #line) {
    checks += 1
    guard let placed = SnapSlotPacker.pack(blocks) else {
        failures += 1
        print("FAIL (\(line)): \(message) - pack() lieferte nil")
        return
    }
    guard placed.count == expected.count else {
        failures += 1
        print("FAIL (\(line)): \(message) - \(placed.count) Zonen statt \(expected.count)")
        return
    }
    for (i, pair) in zip(placed, expected).enumerated() where !rectsAlmostEqual(pair.0.rect, pair.1) {
        failures += 1
        print("FAIL (\(line)): \(message) - Zone \(i)\n  erwartet: \(pair.1)\n  bekommen: \(pair.0.rect)")
        return
    }
}

/// Eine leere, nur fuer diesen Test existierende Einstellungs-Suite - der Store
/// darf die echten Einstellungen des Nutzers nicht anfassen.
func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "snapzonetests.\(name).\(UUID().uuidString)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@main
enum SnapZoneModelTests {
    static func main() {
        testFactoryGeometry()
        testMorePackings()
        testBlocking()
        testFreeWidth()
        testTitles()
        testSnapLayout()
        testStoreBasics()
        testStorePersistence()
        testEmptySlots()
        testNormalization()
        testProfiles()
        testResetToFactory()
        testNotification()

        print("\(checks - failures)/\(checks) Pruefungen bestanden")
        if failures > 0 {
            print("\(failures) fehlgeschlagen")
            exit(1)
        }
        print("OK")
    }

    // MARK: Packen: die fuenf Werksaufteilungen

    // Diese fuenf muessen exakt die Geometrie liefern, die das Panel vor dem
    // Konfigurator hart verdrahtet hatte - sonst springen Fenster nach dem
    // Update woanders hin als vorher.
    static func testFactoryGeometry() {
        checkRects([.full], [r(0, 0, 1, 1)], "Vollbild")

        checkRects([.half, .half],
                   [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)],
                   "Zwei Haelften")

        checkRects([.twoThirds, .third],
                   [r(0, 0, 2.0/3.0, 1), r(2.0/3.0, 0, 1.0/3.0, 1)],
                   "Zwei Drittel + Drittel")

        // Das erste Viertel belegt OBEN, das zweite fuellt darunter nach.
        checkRects([.half, .quarter, .quarter],
                   [r(0, 0, 0.5, 1), r(0.5, 0.5, 0.5, 0.5), r(0.5, 0, 0.5, 0.5)],
                   "Haelfte + zwei Viertel")

        checkRects([.quarter, .quarter, .quarter, .quarter],
                   [r(0, 0.5, 0.5, 0.5), r(0, 0, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5), r(0.5, 0, 0.5, 0.5)],
                   "Vier Viertel")
    }

    // MARK: Packen: weitere gueltige Kombinationen

    static func testMorePackings() {
        checkRects([.third, .third, .third],
                   [r(0, 0, 1.0/3.0, 1), r(1.0/3.0, 0, 1.0/3.0, 1), r(2.0/3.0, 0, 1.0/3.0, 1)],
                   "Drei Drittel")

        checkRects([.third, .half],
                   [r(0, 0, 1.0/3.0, 1), r(1.0/3.0, 0, 0.5, 1)],
                   "Drittel + Haelfte laesst rechts 1/6 frei")

        // Eine offene Viertel-Spalte bleibt nutzbar, auch wenn rechts davon
        // schon ein vollhoher Baustein liegt: dessen Flaeche beginnt rechts der
        // Spalte und kann deren freie untere Haelfte nicht ueberdecken.
        checkRects([.quarter, .half, .quarter],
                   [r(0, 0.5, 0.5, 0.5), r(0.5, 0, 0.5, 1), r(0, 0, 0.5, 0.5)],
                   "Viertel, Haelfte, Viertel fuellt die offene Spalte nach")

        checkRects([], [], "Leerer Slot")
    }

    // MARK: Blockade

    static func testBlocking() {
        check(!SnapSlotPacker.canAppend(.half, to: [.twoThirds]),
              "Haelfte darf nicht zu Zwei Drittel (Beispiel aus der Spezifikation)")
        check(SnapSlotPacker.canAppend(.third, to: [.twoThirds]),
              "Drittel passt zu Zwei Dritteln")
        check(!SnapSlotPacker.canAppend(.third, to: [.twoThirds, .third]),
              "Voller Slot nimmt nichts mehr auf")
        check(!SnapSlotPacker.canAppend(.full, to: [.third]),
              "Vollbild passt nur in einen leeren Slot")
        check(SnapSlotPacker.canAppend(.full, to: []),
              "Vollbild passt in den leeren Slot")
        check(!SnapSlotPacker.canAppend(.half, to: [.full]),
              "Nach Vollbild geht nichts mehr")
        check(!SnapSlotPacker.canAppend(.half, to: [.half, .half]),
              "Zwei Haelften sind voll")

        // Der Fall, an dem eine reine Flaechensumme scheitern wuerde: 1/4 + 1/3
        // + 1/3 sind nur 11/12 Flaeche, geometrisch laeuft der Schreibkopf aber
        // ueber den rechten Rand hinaus (6 + 4 + 4 = 14 Zwoelftel).
        check(SnapSlotPacker.canAppend(.third, to: [.quarter]),
              "Viertel + Drittel passt")
        check(!SnapSlotPacker.canAppend(.third, to: [.quarter, .third]),
              "Viertel + Drittel + Drittel passt NICHT, obwohl die Flaechensumme unter 100% liegt")

        // Ein zweites Viertel kostet keine Breite - es fuellt die offene Spalte.
        // Rechts sind hier nur noch 2/12 frei, ein Viertel braucht aber 6/12: es
        // passt trotzdem, weil es in der offenen Spalte landet.
        check(SnapSlotPacker.canAppend(.quarter, to: [.quarter, .third]),
              "Das zweite Viertel fuellt die offene Spalte und braucht keine neue Breite")

        // Ist die Folge schon fuer sich genommen nicht packbar, laesst sich auch
        // nichts mehr anhaengen - sonst waere `canAppend` nicht mehr gleichbedeutend
        // mit "pack(blocks + [block]) geht".
        check(!SnapSlotPacker.canAppend(.quarter, to: [.quarter, .third, .third]),
              "An ein nicht packbares Praefix laesst sich nichts anhaengen")

        check(SnapSlotPacker.pack([.twoThirds, .half]) == nil,
              "pack() liefert nil fuer eine nicht passende Folge")
    }

    // MARK: Restbreite

    static func testFreeWidth() {
        checkEqual(SnapSlotPacker.freeWidthTwelfths([]), 12, "Leerer Slot: volle Breite frei")
        checkEqual(SnapSlotPacker.freeWidthTwelfths([.twoThirds]), 4, "Nach 2/3 bleiben 4/12")
        checkEqual(SnapSlotPacker.freeWidthTwelfths([.full]), 0, "Vollbild laesst nichts frei")
        checkEqual(SnapSlotPacker.freeWidthTwelfths([.quarter]), 6, "Ein Viertel belegt eine halbe Breite")
        checkEqual(SnapSlotPacker.freeWidthTwelfths([.quarter, .quarter]), 6,
                   "Das zweite Viertel belegt keine zusaetzliche Breite")
    }

    // MARK: Titel

    static func testTitles() {
        checkEqual(SnapSlotPacker.title(for: .full, at: r(0, 0, 1, 1)), "Vollbild", "Titel Vollbild")
        checkEqual(SnapSlotPacker.title(for: .half, at: r(0, 0, 0.5, 1)), "← ½", "Titel linke Haelfte")
        checkEqual(SnapSlotPacker.title(for: .half, at: r(0.5, 0, 0.5, 1)), "→ ½", "Titel rechte Haelfte")
        checkEqual(SnapSlotPacker.title(for: .twoThirds, at: r(0, 0, 2.0/3.0, 1)), "← ⅔",
                   "Titel linke zwei Drittel")
        checkEqual(SnapSlotPacker.title(for: .third, at: r(2.0/3.0, 0, 1.0/3.0, 1)), "→ ⅓",
                   "Titel rechtes Drittel")
        checkEqual(SnapSlotPacker.title(for: .third, at: r(1.0/3.0, 0, 1.0/3.0, 1)), "↔ ⅓",
                   "Titel mittleres Drittel")
        checkEqual(SnapSlotPacker.title(for: .quarter, at: r(0, 0.5, 0.5, 0.5)), "↖ ¼", "Titel oben links")
        checkEqual(SnapSlotPacker.title(for: .quarter, at: r(0.5, 0.5, 0.5, 0.5)), "↗ ¼", "Titel oben rechts")
        checkEqual(SnapSlotPacker.title(for: .quarter, at: r(0, 0, 0.5, 0.5)), "↙ ¼", "Titel unten links")
        checkEqual(SnapSlotPacker.title(for: .quarter, at: r(0.5, 0, 0.5, 0.5)), "↘ ¼", "Titel unten rechts")

        // Die Werksaufteilungen behalten ihre bisherigen Zonentitel.
        if let placed = SnapSlotPacker.pack([.half, .quarter, .quarter]) {
            checkEqual(placed.map { $0.title }, ["← ½", "↗ ¼", "↘ ¼"], "Titel der Werksaufteilung 3")
        } else {
            check(false, "Werksaufteilung 3 liess sich nicht packen")
        }
    }

    // MARK: SnapLayout

    static func testSnapLayout() {
        check(SnapLayout(title: "x", previewRect: r(0, 0, 1, 1)) { $0 }.isFullscreen,
              "Einheitsrechteck ist Vollbild")
        check(!(SnapLayout(title: "x", previewRect: r(0, 0, 0.5, 1)) { $0 }.isFullscreen),
              "Halbe Breite ist kein Vollbild")
        checkEqual(SnapLayout(title: "x", previewRect: .zero) { $0 }.groupID, -1,
                   "Ohne Angabe gehoert ein Layout zu keiner Gruppe")

        // `compute` skaliert das Einheitsrechteck in einen echten Bildschirm-
        // ausschnitt - inklusive Versatz, denn `visibleFrame` beginnt nicht bei (0,0).
        let store = SnapZoneStore(defaults: freshDefaults("compute"))
        store.slots = [[.half, .half], [], [], [], []]
        let screen = CGRect(x: 100, y: 50, width: 1600, height: 900)
        let zone = store.groups[0].zones[1]
        check(rectsAlmostEqual(zone.compute(screen), CGRect(x: 900, y: 50, width: 800, height: 900)),
              "compute() rechnet das Einheitsrechteck in den Bildschirm um, bekommen: \(zone.compute(screen))")
    }

    // MARK: Store

    static func testStoreBasics() {
        let store = SnapZoneStore(defaults: freshDefaults("fresh"))
        checkEqual(store.slots, SnapZoneDefaults.factorySlots,
                   "Frischer Store startet mit der Werkseinstellung")
        checkEqual(store.profiles.count, 0, "Frischer Store hat keine Profile")
        checkEqual(store.groups.count, 5, "Werkseinstellung ergibt fuenf Kacheln")
        checkEqual(store.groups.map { $0.id }, [0, 1, 2, 3, 4], "Gruppen-IDs sind die Slot-Indizes")
        checkEqual(store.groups[4].zones.count, 4, "Slot 4 hat vier Viertel")
        check(store.groups.allSatisfy { g in g.zones.allSatisfy { $0.groupID == g.id } },
              "Jede Zone kennt ihre Gruppe")
    }

    static func testStorePersistence() {
        let defaults = freshDefaults("persist")
        let a = SnapZoneStore(defaults: defaults)
        a.slots = [[.third, .third, .third], [], [.full], [], []]
        a.saveProfile(named: "Arbeit")

        let b = SnapZoneStore(defaults: defaults)
        checkEqual(b.slots, [[.third, .third, .third], [], [.full], [], []],
                   "Slots ueberdauern einen Neustart")
        checkEqual(b.profiles.map { $0.name }, ["Arbeit"], "Profile ueberdauern einen Neustart")
    }

    static func testEmptySlots() {
        let store = SnapZoneStore(defaults: freshDefaults("empty"))
        store.slots = [[], [.half, .half], [], [.full], []]
        checkEqual(store.groups.count, 2, "Nur belegte Slots werden zu Kacheln")
        checkEqual(store.groups.map { $0.id }, [1, 3], "Die Gruppen-IDs bleiben die Slot-Indizes")
    }

    static func testNormalization() {
        let store = SnapZoneStore(defaults: freshDefaults("normalize"))
        store.slots = [[.full]]
        checkEqual(store.slots.count, 5, "Zu kurze Eingabe wird auf fuenf Slots aufgefuellt")
        checkEqual(store.slots[4], [], "Aufgefuellt wird mit leeren Slots")

        store.slots = Array(repeating: [.full], count: 8)
        checkEqual(store.slots.count, 5, "Zu lange Eingabe wird abgeschnitten")

        store.slots = [[.twoThirds, .half, .third], [], [], [], []]
        checkEqual(store.slots[0], [.twoThirds],
                   "Ein nicht packbarer Slot wird auf das packbare Praefix gekuerzt")
    }

    static func testProfiles() {
        let store = SnapZoneStore(defaults: freshDefaults("profiles"))

        store.slots = [[.full], [], [], [], []]
        check(store.saveProfile(named: "Arbeit"), "Erstes Profil laesst sich sichern")
        store.slots = [[.half, .half], [], [], [], []]
        check(store.saveProfile(named: "Gaming"), "Zweites Profil laesst sich sichern")
        store.slots = [[.third, .third, .third], [], [], [], []]
        check(store.saveProfile(named: "Ultrawide"), "Drittes Profil laesst sich sichern")
        check(!store.saveProfile(named: "Viertes"), "Ein viertes Profil wird abgelehnt")
        checkEqual(store.profiles.count, 3, "Es bleiben drei Profile")

        // Gleicher Name = Ueberschreiben, auch wenn die Obergrenze erreicht ist.
        store.slots = [[.quarter, .quarter, .quarter, .quarter], [], [], [], []]
        check(store.saveProfile(named: "Arbeit"), "Ein bestehendes Profil laesst sich ueberschreiben")
        checkEqual(store.profiles.count, 3, "Ueberschreiben legt kein zusaetzliches Profil an")
        checkEqual(store.profiles.map { $0.name }, ["Arbeit", "Gaming", "Ultrawide"],
                   "Ueberschreiben behaelt die Reihenfolge")
        checkEqual(store.profiles[0].slots[0], [.quarter, .quarter, .quarter, .quarter],
                   "Ueberschreiben uebernimmt die aktuelle Konfiguration")

        check(!store.saveProfile(named: "   "), "Ein leerer Name wird abgelehnt")
        checkEqual(store.profiles.count, 3, "Der abgelehnte Name legt nichts an")

        check(store.applyProfile(named: "Gaming"), "Ein vorhandenes Profil laesst sich anwenden")
        checkEqual(store.slots[0], [.half, .half], "Anwenden uebernimmt die Slots des Profils")
        check(!store.applyProfile(named: "Gibtsnicht"), "Ein unbekanntes Profil wird abgelehnt")

        store.deleteProfile(named: "Gaming")
        checkEqual(store.profiles.map { $0.name }, ["Arbeit", "Ultrawide"],
                   "Loeschen entfernt genau ein Profil")
        store.deleteProfile(named: "Gibtsnicht")
        checkEqual(store.profiles.count, 2, "Ein unbekannter Name zu loeschen ist kein Fehler")
        check(store.saveProfile(named: "Neu"), "Nach dem Loeschen ist wieder Platz")
    }

    static func testResetToFactory() {
        let store = SnapZoneStore(defaults: freshDefaults("reset"))
        store.slots = [[.full], [], [], [], []]
        store.saveProfile(named: "Arbeit")
        store.resetToFactory()
        checkEqual(store.slots, SnapZoneDefaults.factorySlots,
                   "Zuruecksetzen stellt die Werkseinstellung her")
        checkEqual(store.profiles.map { $0.name }, ["Arbeit"], "Zuruecksetzen laesst die Profile in Ruhe")
    }

    static func testNotification() {
        let store = SnapZoneStore(defaults: freshDefaults("notify"))
        var seen = 0
        let token = NotificationCenter.default.addObserver(
            forName: .snapZonesDidChange, object: nil, queue: nil) { _ in seen += 1 }
        store.slots = [[.full], [], [], [], []]
        checkEqual(seen, 1, "Slots setzen meldet die Aenderung")
        store.resetToFactory()
        checkEqual(seen, 2, "Zuruecksetzen meldet die Aenderung")
        store.applyProfile(named: "gibtsnicht")
        checkEqual(seen, 2, "Ein fehlgeschlagenes Anwenden meldet nichts")
        NotificationCenter.default.removeObserver(token)
    }
}

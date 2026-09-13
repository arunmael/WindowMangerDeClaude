# Feature-Spezifikation: Ganze Bildschirmgröße vs. echtes Vollbild

## 1. Grundidee

Bisher gab es nur einen Zustand: die „Vollbild“-Kachel zog das Fenster auf die
nutzbare Bildschirmfläche (`visibleFrame`) auf. Echtes macOS-Vollbild — eigener
Space, ausgeblendete Menüleiste — war gar nicht erreichbar. Ab jetzt sind das
zwei getrennte Ziele.

## 2. Ganze Bildschirmgröße (Maximieren)

Sobald das Snap-Panel erscheint und der Zeiger **keine** Zonen-Kachel trifft,
zeigt die Zielvorschau die volle nutzbare Bildschirmfläche; Loslassen maximiert
das Fenster.

Das gilt in genau zwei Bereichen:

* im Panel selbst, also auch in den Lücken zwischen den Kacheln,
* im Streifen **oberhalb** des Panels bis zum oberen Bildschirmrand — dort steht
  der Zeiger, direkt nachdem das Panel aufgetaucht ist.

Überall sonst passiert nichts: ein Loslassen mitten auf dem Schreibtisch darf das
Fenster nicht ungefragt aufziehen. Der Bereich ist als reine Rechteckfrage in
`SnapPanelHitRegion.isMaximize` abgelegt und damit ohne laufende App prüfbar.

## 3. Echtes Vollbild

Die Vollbild-Kachel aus **Slot 0** (`SnapZoneDefaults.nativeFullscreenSlot`)
setzt `AXFullScreen` auf dem Fenster und schickt es damit in den echten
Vollbildmodus. Die Zielvorschau bezieht sich dafür auf `screen.frame` statt auf
`visibleFrame` und überdeckt sichtbar auch die Menüleiste — so unterscheidet sie
sich auf einen Blick vom Maximieren.

Dieselbe `.full`-Form in einem anderen Slot maximiert weiterhin nur. Eine selbst
zusammengebaute Anordnung soll nicht ungewollt Spaces aufmachen.

## 4. Randfälle

* Unterstützt ein Fenster `AXFullScreen` nicht (Dialoge, ältere Apps), fällt das
  Snappen auf das bisherige Maximieren zurück.
* Beim Wechsel in echtes Vollbild wird der gemerkte Rahmen vor dem Snap verworfen:
  im eigenen Space ist er kein sinnvolles Wiederherstellungsziel mehr.
* Der Space-Wechsel animiert rund eine Sekunde und meldet die ganze Zeit
  Fensterbewegungen. Die Sperre für selbst ausgelöste Bewegungen läuft deshalb
  länger nach als bei einem gewöhnlichen Snap, sonst gälte die Systemanimation
  als neue Ziehgeste.

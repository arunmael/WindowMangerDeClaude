# Feature-Spezifikation: Eigene Snap-Zonen konfigurieren

## 1. Grundidee
Nutzer sollen nicht mehr ausschließlich auf fest vorgegebene Fenster-Layouts angewiesen sein, sondern ihre eigenen Snap-Zonen-Layouts zusammenstellen können. Dafür wird in den Einstellungen der App in der Seitenleiste ein neuer Menüpunkt namens **"Konfiguriere Snap Zonen"** hinzugefügt. Das Feature funktioniert nach einem intuitiven Drag-and-Drop-Prinzip.

## 2. Aufbau der Benutzeroberfläche (UI)
Die Einstellungs-Ansicht ist vertikal in zwei Hauptbereiche unterteilt:

* **Oberer Bereich (Das Live-Panel):** Hier wird das Snap-Zonen-Panel mit seinen **5 konfigurierbaren Slots** angezeigt (optisch identisch zum aktuellen Pop-up-Panel). Zieht man einen Baustein in einen Slot, wird sofort visuell dargestellt, dass die Zone nun in diesem Slot hinterlegt ist.
* **Unterer Bereich (Die Bausteine):** Hier befindet sich das „Inventar“. Es zeigt die verfügbaren Rechtecke (Zonen-Bausteine), die der Nutzer per Maus fassen und nach oben in die Slots ziehen kann.

## 3. Verfügbare Zonen-Bausteine
Die Formen der Zonen entsprechen exakt den Proportionen der Standard-Layouts. Die Nutzer können folgende Bausteine verwenden und neu kombinieren:

1. **Fullscreen** (1/1 - gesamter Bildschirm)
2. **Zwei Drittel** (2/3 der Breite)
3. **Ein halbes Fenster** (1/2 der Breite/Höhe)
4. **Ein Drittel** (1/3 der Breite)
5. **Ein Viertel** (1/4 des Bildschirms)

## 4. Drag-and-Drop Logik & Regeln
* **Automatische Blockade bei Platzmangel:** Ein Slot entspricht maximal einem vollen Bildschirm (100%). Das UI verhindert (blockiert) das Hineinziehen eines weiteren Bausteins, wenn der Platz im jeweiligen Slot nicht mehr ausreicht. *(Beispiel: Es ist nicht möglich, eine "Ein halbes Fenster"-Zone in einen Slot zu ziehen, der bereits mit "Zwei Drittel" befüllt ist).*
* **Anordnung:** Die Zonen behalten ihre Grundformen (wie bisher im System bekannt). Der Unterschied besteht lediglich darin, dass der Nutzer sie frei in den 5 Slots zusammenstellen kann.

## 5. Speichern, Profile und Defaults
Um den Nutzern den Wechsel zwischen verschiedenen Workflows zu erleichtern, gibt es folgende Speicher- und Wiederherstellungsfunktionen:

* **Eigene Anordnungen (Profile):** Nutzer können bis zu **3 eigene, komplette Panel-Konfigurationen** erstellen und unter einem **eigenen Namen** (z.B. "Arbeit", "Gaming", "Ultrawide") abspeichern.
* **"Use Default"-Button:** Es gibt einen gut sichtbaren Button ("Standard wiederherstellen"), der das Panel mit einem Klick auf die werksseitigen 5 Standard-Layouts zurücksetzt.
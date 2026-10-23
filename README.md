# Fontwerk

Eigene Schriftverwaltung für macOS, nativ für Apple Silicon (und Intel). Läuft ab macOS 14 Sonoma.

## Funktionen (Version 0.1)

- Schriften und ganze Ordner importieren, per Dialog oder per Drag & Drop
- Wahlweise Kopie in den eigenen Bibliotheksordner (`~/Library/Application Support/Fontwerk/Fonts`) oder Verweis auf den bisherigen Ort
- Duplikate werden beim Import erkannt und übersprungen
- Aktivieren bis zum Abmelden oder dauerhaft, Deaktivieren; Doppelklick schaltet um
- Vorschau auch für inaktive Schriften: Mustertext, Wasserfall, Zeichenübersicht, Detailinformationen
- Sets anlegen, umbenennen, löschen und als Ganzes aktivieren
- Bewertungen, Favoriten und Tags
- Suche über Name, Familie, PostScript-Name, Hersteller und Tags
- Erkennt fehlende Dateien und gleicht den Aktivierungsstatus beim Start mit macOS ab

Geplant: Konflikterkennung, Smart Sets, Druck, Import einer bestehenden FontExplorer-X-Bibliothek, Ähnlichkeitssuche, Plugins für Adobe-Programme.

## App herunterladen

Bei jedem Push baut GitHub die App automatisch.

1. Im Repository auf **Actions** gehen und den obersten erfolgreichen Lauf von **Build** öffnen.
2. Unten unter **Artifacts** die Datei `Fontwerk-…` herunterladen und entpacken.
3. `Fontwerk.app` in den Ordner **Programme** ziehen.
4. Die App ist nicht von Apple beglaubigt. Vor dem ersten Start einmal im Terminal ausführen:

   ```
   xattr -dr com.apple.quarantine /Applications/Fontwerk.app
   ```

## Selbst bauen

Mit installierten Command Line Tools (`xcode-select --install`):

```
./scripts/package_app.sh
```

Das Ergebnis liegt in `build/Fontwerk.app`.

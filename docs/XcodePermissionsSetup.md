# Xcode + macOS Permissions Setup (Microphone / ScreenCapture)

Dit project is een Swift Package. Als je de executable direct draait (bijv. via `swift run` of package-run in Xcode), kan macOS TCC permissies koppelen aan de host in plaats van aan een stabiele app-bundle.  
Voor betrouwbare tests: bouw en run een echte `.app` met vaste bundle identifier.

## 1) Controleer dat volledige Xcode actief is

```bash
xcode-select -p
```

Als je hier alleen CommandLineTools ziet, zet dan volledige Xcode actief:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2) Info.plist en bundle-id in dit project

De app metadata en privacy-teksten staan in:

- `/Users/leonard/Downloads/AI-note-taker/Sources/AINoteTakerApp/Resources/AppInfo.plist`

Belangrijk:

- `CFBundleIdentifier` is vast gezet op `com.vepando.minutewave`
- `NSMicrophoneUsageDescription` staat ingevuld
- screen/system-audio beschrijvingen staan ingevuld voor duidelijke UX

## 3) Bouw een stabiele app-bundle voor permissietests

```bash
cd /Users/leonard/Downloads/AI-note-taker
./scripts/build_dev_app_bundle.sh
```

Dit bouwt:

- `/Users/leonard/Downloads/AI-note-taker/.build/AppBundle/MinuteWave.app`

## 4) Reset permissies en test opnieuw

```bash
./scripts/reset_tcc_permissions.sh
open "/Users/leonard/Downloads/AI-note-taker/.build/AppBundle/MinuteWave.app"
```

Daarna in macOS Settings:

1. Privacy & Security -> Microphone -> zet `MinuteWave` aan
2. Privacy & Security -> Screen & System Audio Recording -> zet `MinuteWave` aan
3. Sluit en heropen de app na ScreenCapture wijziging

Belangrijk:

- Runtime permissie-validatie is leidend. Onboardingstatus alleen is niet voldoende als macOS de wijziging nog niet actief heeft gemaakt.
- Na wijziging van Screen Recording permissie blijft een herstart van `MinuteWave` vereist.

## 5) Verwacht gedrag

1. Eerste opname triggert permissieprompt(s)
2. Microfoonindicator moet zichtbaar zijn tijdens opname
3. Als ScreenCapture niet actief is, blijft mic-only werken (met duidelijke waarschuwing in UI)

## 6) Veelvoorkomende valkuilen

1. Bundle ID wisselt per build -> permissies lijken "weg"
2. Instabiele code-signing identity -> TCC ziet een nieuwe app-identiteit na update
3. App draait niet als echte `.app` -> TCC koppelt aan hostproces
4. Tweede stop tijdens finalisatie -> foutmelding (is in code inmiddels idempotent gemaakt)

Opmerking signing:

- `scripts/build_dev_app_bundle.sh` gebruikt voor ad-hoc builds een stabiele designated requirement op basis van `CFBundleIdentifier`, zodat permissies beter mee kunnen gaan tussen lokale updates.
- Voor distributie/release blijft een echte signing identity (Apple Development / Developer ID) aanbevolen.

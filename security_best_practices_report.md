# Security Best Practices Report

## Executive Summary

Deze codebase is een lokale macOS app (Swift + lokale Python runtime) met focus op privacygevoelige transcriptie-data. De grootste risico's zitten niet in klassieke remote web-aanvalsvectoren, maar in privacybescherming op schijf, netwerkconfiguratie naar cloud-endpoints en supply-chain/execution risico's in de lokale runtime-setup.

Belangrijkste conclusie: de app toont een encryptie-optie, maar slaat transcriptie/samenvattingen nog plaintext op. Daarnaast wordt voor Azure geen HTTPS afgedwongen en kan de lokale runtime (bij misconfiguratie) zonder authenticatie op niet-loopback adressen luisteren.

## Scope & Method

- Geanalyseerde talen/frameworks:
  - Swift (SwiftUI, Foundation, Security, SQLite3)
  - Python (lokale websocket runtime scripts)
- Lokale threat model aannames:
  - App draait op eindgebruikersmachine.
  - Aanvallen zijn vooral: datalek op lokale opslag, misconfiguratie die audio/keys exfiltreert, supply-chain risico bij dependency install.
- Opmerking over skill-referenties:
  - In de skill-references zijn geen Swift-specifieke documenten aanwezig; bevindingen voor Swift zijn gebaseerd op algemene secure-by-default principes.

## High Severity

### SBP-001: Encryptie-toggle geeft schijnveiligheid; data staat plaintext in SQLite

- Impact: gevoelige notities/transcripties kunnen uitlekken bij lokale compromise, backup-extractie of ongeautoriseerde accounttoegang terwijl gebruiker denkt dat encryptie aan staat.
- Evidence:
  - Encryptie-optie in settings UI: `Sources/AINoteTakerApp/Features/Settings/SettingsView.swift:121`
  - Configveld + default `true`: `Sources/AINoteTakerApp/Domain/Models.swift:221` en `Sources/AINoteTakerApp/Domain/Models.swift:240`
  - SQLite opent zonder SQLCipher key/bootstrap: `Sources/AINoteTakerApp/Data/SQLiteRepository.swift:20`
- Aanbevolen fix:
  - Implementeer echte at-rest encryptie (SQLCipher of equivalent) en koppel die hard aan `encryptionEnabled`.
  - Toon expliciet in UI wanneer encryptie niet actief is, en migreer bestaande plaintext DB gecontroleerd.

### SBP-002: Azure endpoint valideert URL, maar dwingt geen HTTPS af

- Impact: API keys en transcriptie-inhoud kunnen bij `http://` endpointconfiguratie onversleuteld verstuurd worden.
- Evidence:
  - Alleen URL-validatie, geen scheme-check: `Sources/AINoteTakerApp/Services/AzureResponsesServices.swift:10`
  - API-key wordt direct als header meegestuurd: `Sources/AINoteTakerApp/Services/AzureResponsesServices.swift:58`
  - Zelfde patroon voor transcriptie-aanroepen: `Sources/AINoteTakerApp/Services/AzureTranscriptionProvider.swift:177` en `Sources/AINoteTakerApp/Services/AzureTranscriptionProvider.swift:210`
- Aanbevolen fix:
  - Sta alleen `https` toe voor Azure-endpoints.
  - Fail fast in onboarding/settings met duidelijke foutmelding bij niet-HTTPS.

## Medium Severity

### SBP-003: Lokale realtime server heeft geen auth en kan via host-misconfiguratie extern bereikbaar worden

- Evidence:
  - App genereert runtime command op basis van endpoint-host: `Sources/AINoteTakerApp/App/AppViewModel.swift:932`
  - Settings laat endpoint vrij aanpassen: `Sources/AINoteTakerApp/Features/Settings/SettingsView.swift:133`
  - Python runtime accepteert host/port argumenten en start server zonder auth-handshake: `scripts/parakeet_mlx_realtime_server.py:306` en `scripts/parakeet_mlx_realtime_server.py:693`
- Risico:
  - Bij host `0.0.0.0` of LAN-IP kunnen andere systemen op het netwerk de runtime benaderen.
- Aanbevolen fix:
  - Forceer loopback (`127.0.0.1`/`localhost`) als veilige default.
  - Voeg opt-in “allow remote clients” met expliciete waarschuwing toe.
  - Voeg minimaal bearer token of local-only unix socket mechanisme toe bij non-loopback.

### SBP-004: Ongepinde dependency auto-install + `--trusted-host` vergroot supply-chain risico

- Evidence:
  - App installeert runtime deps met `pip install -U` en git fallback: `Sources/AINoteTakerApp/App/AppViewModel.swift:1121` en `Sources/AINoteTakerApp/App/AppViewModel.swift:1125`
  - Script gebruikt o.a. `--trusted-host` pypi hosts: `scripts/parakeet_mlx_realtime_server.py:121`
- Risico:
  - Niet-reproduceerbare builds en groter risico op kwaadwillige/compromised package updates.
- Aanbevolen fix:
  - Pin versies/hashes (`--require-hashes`) in requirements lockfile.
  - Vermijd `--trusted-host` tenzij strikt noodzakelijk en gedocumenteerd.
  - Maak auto-install opt-in in plaats van default.

## Low Severity

### SBP-005: Runtime command execution via `zsh -lc` met instellingen uit persistente config

- Evidence:
  - Shell execution van command-string: `Sources/AINoteTakerApp/Services/LocalRuntimeManager.swift:35`
  - Runtime command komt uit settings: `Sources/AINoteTakerApp/App/AppViewModel.swift:687`
  - `modelId` wordt in command-string geïnterpoleerd zonder escaping van quotes: `Sources/AINoteTakerApp/App/AppViewModel.swift:938`
- Risico:
  - Bij gecompromitteerde settings kan arbitrary command execution plaatsvinden onder user-context.
- Aanbevolen fix:
  - Vermijd shell-string; gebruik `Process.executableURL` + gescheiden argument-array.
  - Sanitize/whitelist model IDs en hosts.

### SBP-006: Keychain items zonder expliciete `kSecAttrAccessible` policy

- Evidence:
  - Bij `SecItemAdd` wordt geen accessibility class gezet: `Sources/AINoteTakerApp/Utilities/KeychainStore.swift:22`
- Risico:
  - Minder expliciete controle over wanneer secrets beschikbaar zijn.
- Aanbevolen fix:
  - Zet expliciet `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (of stricter policy passend bij UX).

## Suggested Remediation Order

1. SBP-001 (echte encryptie of toggle tijdelijk verwijderen/waarschuwen)
2. SBP-002 (HTTPS enforcement voor Azure)
3. SBP-003 (loopback enforcement + auth bij non-loopback)
4. SBP-004 (dependency installatie hardenen)
5. SBP-005, SBP-006 (command execution/keychain hardening)


# GitHub Actions release secrets

These values are required for GitHub-hosted release builds. Never commit
certificates, private keys, app-specific passwords, or `.p8` files to the
repository.

## Team ID safety

The Apple Team ID is not a secret. It is visible in signed app metadata,
certificates, provisioning profiles, and App Store Connect records. It is safe
to use as a GitHub secret or variable, and it is normal for users to see it in a
signed app. The private key inside the signing certificate, App Store Connect
API key, and app-specific passwords are the sensitive materials.

## Direct download DMG

The `Release DMG` workflow creates GitHub Releases from tags matching `v*.*.*`,
or from manual workflow dispatches when `publish_release` is enabled.
Distribution releases intentionally fail unless Developer ID signing and
notarization credentials are configured.

Required secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Base64-encoded `.p12` for `Developer ID Application: ...` |
| `MACOS_CERT_PASSWORD` | Password for the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Exact identity name, for example `Developer ID Application: Example (TEAMID)` |
| `APPLE_NOTARY_APPLE_ID` | Apple Account email for notarization |
| `APPLE_NOTARY_PASSWORD` | App-specific password or keychain password reference |
| `APPLE_NOTARY_TEAM_ID` | Apple Team ID |

Alternatively, notarization may use an App Store Connect API key:

| Secret | Purpose |
| --- | --- |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID, or reuse `ASC_API_KEY_ID` |
| `APPLE_NOTARY_ISSUER_ID` | Issuer ID for team keys; omit/ignore for individual keys |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded private `.p8` key, or reuse `ASC_API_KEY_P8_BASE64` |
| `APPLE_NOTARY_KEY_SUBJECT` | Set to `user` for individual API keys |

Legacy `APPLE_DEV_*` signing secrets are still read for compatibility, but real
distribution DMGs require `MACOS_SIGNING_IDENTITY` to be a Developer ID
Application identity.

## TestFlight package

The `TestFlight Package` workflow builds a signed macOS package. It validates
with App Store Connect only when the manual `validate` input is true, and it
uploads only when `upload` is true.

Required signing secrets:

| Secret | Purpose |
| --- | --- |
| `MAC_APPLE_DISTRIBUTION_CERT_P12_BASE64` | Base64-encoded `.p12` for `Apple Distribution: ...` |
| `MAC_APPLE_DISTRIBUTION_CERT_PASSWORD` | Password for the app distribution `.p12` |
| `MAC_APPLE_DISTRIBUTION_SIGNING_IDENTITY` | Exact `Apple Distribution: ...` identity name |
| `MAC_APP_STORE_PROVISIONING_PROFILE_BASE64` | Base64-encoded Mac App Store provisioning profile for `com.vepando.minutewave` |
| `MAC_INSTALLER_CERT_P12_BASE64` | Base64-encoded `.p12` for `3rd Party Mac Developer Installer: ...` |
| `MAC_INSTALLER_CERT_PASSWORD` | Password for the installer `.p12` |
| `MAC_INSTALLER_SIGNING_IDENTITY` | Exact `3rd Party Mac Developer Installer: ...` identity name |

The provisioning profile must be created in Apple Developer
Certificates, Identifiers & Profiles for the explicit App ID
`com.vepando.minutewave`, team `RU59889W67`, and the same Apple Distribution
certificate used by the workflow. GitHub Actions embeds it as
`MinuteWave.app/Contents/embedded.provisionprofile` before the final app
codesign step. Without this profile, App Store Connect accepts the upload but
marks the macOS build unavailable for TestFlight with `ITMS-90889`.

Use one App Store Connect authentication method:

| Secret | Purpose |
| --- | --- |
| `ASC_API_KEY_ID` | App Store Connect API key ID |
| `ASC_API_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_API_KEY_P8_BASE64` | Base64-encoded private `.p8` key |
| `ASC_PROVIDER_PUBLIC_ID` | Optional provider public ID when the account has multiple providers |

or:

| Secret | Purpose |
| --- | --- |
| `ASC_USERNAME` | Apple Account email |
| `ASC_PASSWORD` | App-specific password or `@keychain:` reference |
| `ASC_PROVIDER_PUBLIC_ID` | Optional provider public ID |

## Pages

The `Publish Pages` workflow deploys the static site from `docs/` to GitHub
Pages on pushes to `main` that touch the docs site, and on manual dispatch.

# juancode iOS (`juancode-3aq8`)

SwiftUI iPhone client for the Mac's `:4280` relay, over Tailscale (see
`apps/native/README.md` → _Phone access over Tailscale_). Links `JuancodeWire` from
`apps/native` and SwiftTerm.

| Folder        | role                                                                  |
| ------------- | --------------------------------------------------------------------- |
| `Connection/` | `Pairing` (QR link + Keychain), `RemoteCore` (`/ws` + REST, token)    |
| `Models/`     | view-shaped data (`ProjectGroup`)                                     |
| `Views/`      | pairing, drawer, session terminal + key row; new panels go here       |

- Pair: scan the QR in the Mac's Settings → Phone, or paste its `juancode://pair?…` link.
- `juancode://session/<id>` opens a session.
- `project.yml` is the source of truth; run `xcodegen` after adding files.
  `Juancode.xcodeproj` is generated and checked in.
- Build (simulator): `xcodebuild -project Juancode.xcodeproj -scheme Juancode
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
  On a device, sign with a free Apple ID (Signing & Capabilities → Team).

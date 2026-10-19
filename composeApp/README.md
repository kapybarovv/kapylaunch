# kapylauncher (Kotlin desktop)

Run the interactive desktop app from the repository root:

```sh
./gradlew -p composeApp run
```

Microsoft sign-in uses the registered public OAuth client ID. For local development it can be supplied at runtime; it is not stored in source files:

```sh
KAPYLAUNCHER_MICROSOFT_CLIENT_ID="<your-client-id>" ./gradlew -p composeApp run
```

On PowerShell:

```powershell
$env:KAPYLAUNCHER_MICROSOFT_CLIENT_ID = "<your-client-id>"
.\gradlew.bat -p composeApp run
```

The launcher fetches vanilla metadata from Mojang, Fabric loader profiles from Fabric Meta, and Forge promotions/installers from Forge's Maven repository. Game data and per-profile instance directories live in a `.kapylauncher` folder under the current user's home directory; Microsoft refresh credentials are delegated to the platform credential store (macOS Keychain, Windows DPAPI, or Linux Secret Service).

## GitHub Actions

The release workflow builds native packages from this Kotlin/Compose project for Linux x64, Windows x64, Apple Silicon, and Intel Macs. On version tags (`kapylauncher-v*`) it attaches those installers to a GitHub Release. To enable Microsoft sign-in in CI-built packages, add a repository Actions secret named `KAPYLAUNCHER_MICROSOFT_CLIENT_ID`. The client ID is a public OAuth identifier, not a password; a distributed desktop binary can be inspected, so it cannot be kept secret from its users.

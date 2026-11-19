# Amer Teams on iPhone

## Free testing (no Apple Developer account)
1. Download **AmerTeams-unsigned.ipa** from the latest GitHub Actions run (Artifacts → *amer-teams-ios-unsigned*).
2. On your Windows PC install **iTunes** (from apple.com, not the Microsoft Store version) and **Sideloadly** (sideloadly.io).
3. Connect the iPhone by USB, tap *Trust this computer*.
4. Open Sideloadly, drag in the .ipa, enter your normal Apple ID, click **Start**.
5. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. On iOS 16+ also turn on Settings → Privacy & Security → **Developer Mode** and restart.

Limits of the free route (Apple rules): the app must be re-installed every **7 days** (Sideloadly can refresh it), at most 3 sideloaded apps, and **push notifications do not work**, so keep the app open to receive calls. Chat, calls, meetings, files and the AI co-pilot work normally.
The app is allowed plain HTTP **only to your local network** (Apple's `NSAllowsLocalNetworking`), so it works with the `http://<PC-IP>` Wi-Fi test mode. iOS asks once for *Local Network* permission: tap **Allow**. Internet servers still require HTTPS.

## Paid route: TestFlight (for many testers)

Apple only lets signed apps run on a real iPhone. Until the Apple secrets below are added, GitHub builds the iOS app **unsigned** (proves it compiles). Once they are added, every push builds a signed app and uploads it to **TestFlight**; testers install it from the TestFlight app.

## One-time setup (about 30 minutes)
1. **Apple Developer Program** — enrol at developer.apple.com/programs ($99/year). Note your **Team ID** (Membership details).
2. **App ID** — Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → Bundle ID `com.amerteams.app`. Tick *Push Notifications*.
3. **Distribution certificate** — on a Mac: Keychain Access → Certificate Assistant → *Request a Certificate…* → upload at Certificates → **+** → *Apple Distribution*. Download, double-click, then export it from Keychain as **cert.p12** with a password.
   (No Mac? Create the request with OpenSSL: `openssl req -new -newkey rsa:2048 -nodes -keyout key.pem -out request.csr -subj "/CN=Amer Teams"`, then after downloading `distribution.cer`: `openssl x509 -in distribution.cer -inform DER -out cert.pem && openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12`.)
4. **Provisioning profile** — Profiles → **+** → *App Store Connect* → App ID `com.amerteams.app` → your certificate → download **amer.mobileprovision**.
5. **App Store Connect app** — appstoreconnect.apple.com → My Apps → **+** → New App, bundle ID `com.amerteams.app`, name "Amer Teams".
6. **API key for uploads** — App Store Connect → Users and Access → Integrations → **+** (role *App Manager*). Note **Key ID** and **Issuer ID**, download **AuthKey_XXXX.p8**.

## Add the secrets to GitHub
Repository → Settings → Secrets and variables → Actions → *New repository secret*:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | your Team ID |
| `IOS_CERT_P12_BASE64` | `base64 -i cert.p12` (PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12"))`) |
| `IOS_CERT_PASSWORD` | the .p12 password |
| `IOS_PROVISION_PROFILE_BASE64` | base64 of `amer.mobileprovision` |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | base64 of `AuthKey_XXXX.p8` |

Push any commit (or Actions → Build Amer Teams apps → *Run workflow*). After about 20 minutes the build appears in App Store Connect → TestFlight. Add yourself as an internal tester and install from the **TestFlight** app on the iPhone.

## Notes
- Calls between iPhone, Android and Windows work through the same server; use a server reachable by all devices (public domain with HTTPS for iPhone, because iOS blocks plain HTTP by default).
- Incoming-call push on iPhone also needs the APNs key described in docs/PUSH.md.

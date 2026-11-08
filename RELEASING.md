# Releasing Map Lock

This is how to make a `MapLock.zip` that friends can download and open with no "cannot verify" warning.
You need your paid Apple Developer account and the Command Line Tools (`xcode-select --install`). No Xcode app needed.

## One-time setup

### 1. Make a Developer ID Application certificate

1. Open **Keychain Access** (Command Space, type Keychain Access).
2. In the menu bar pick **Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority**.
3. Type your email and name, pick **Saved to disk**, and click Continue. This saves a `.certSigningRequest` file.
4. Go to [developer.apple.com/account](https://developer.apple.com/account), then **Certificates, IDs & Profiles > Certificates**, and click **+**.
5. Pick **Developer ID Application**, click Continue, and upload the file from step 3.
6. Download the `.cer` file and double click it. It goes into your keychain.
7. Check it worked:
   ```
   security find-identity -v -p codesigning
   ```
   You should see a line like `Developer ID Application: Your Name (ABCDE12345)`.
   The part in brackets is your **Team ID**.

Only the Account Holder can make this certificate. On a personal account, that is you.
Keep the Mac (or a backup of the key) safe: the private key lives only in your keychain.

### 2. Make an app-specific password

1. Go to [account.apple.com](https://account.apple.com) and sign in.
2. Open **Sign-In and Security > App-Specific Passwords** and make a new one (name it "notarytool").
3. Copy it. It looks like `abcd-efgh-ijkl-mnop`.

### 3. Save your login for notarization

```
xcrun notarytool store-credentials maplock-notary --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID --password abcd-efgh-ijkl-mnop
```

It should say "Credentials saved to Keychain". You only do this once.

### 4. Sparkle tools and the update key

Sparkle 2.10.1 is linked by Swift Package Manager. The `sign_update` tool is separate. It is expected at:

```
~/SparkleTools/bin/sign_update
```

On this Mac that is `/Users/elliotma/SparkleTools/bin/sign_update`. If the tools live somewhere else, set `SPARKLE_BIN` to that `bin` folder.

The EdDSA private key is already in the login keychain. `sign_update` reads it from there. Do not pass a key file. The matching public key is `SUPublicEDKey` in the app (`4B/Zgi67ePGtK4eStqHuoHW/ad6YKevp+6SZ1petro4=`).

## Each release

1. Make the zip (pick the new version number):
   ```
   VERSION=1.3.3 ./release.sh
   ```
   It builds, copies `Sparkle.framework` into `Contents/Frameworks`, sets the executable rpath to `@executable_path/../Frameworks`, and signs inside-out with Developer ID and the hardened runtime: `Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`, the framework, then the app. Map Lock is not sandboxed, so those XPC services are not launched. They are signed because notarization rejects an unsigned bundle nested in the framework.
   It sends the app to Apple, waits (usually a few minutes), staples the result, and checks it.
   At the end you get `dist/MapLock.zip`. The script then runs `sign_update` on that zip and writes `dist/sparkle-signature.txt`. That file looks like:
   ```
   sparkle:edSignature="..." length="12345"
   ```
2. Add an item to `appcast.xml` at the top of `<channel>`, commit it to `main`, and push. People receive updates from `https://raw.githubusercontent.com/oiwdis/map-lock/main/appcast.xml`. `sparkle:version` must match `CFBundleVersion` in the build. The build script sets that to the marketing version (`1.3.0`) unless you pass `BUILD_NUMBER`. `sparkle:shortVersionString` is the same version people see.
   ```xml
   <item>
     <title>Version 1.3.0</title>
     <pubDate>Sat, 07 Nov 2026 20:00:00 +0000</pubDate>
     <sparkle:version>1.3.0</sparkle:version>
     <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
     <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
     <enclosure url="https://github.com/oiwdis/map-lock/releases/download/v1.3.0/MapLock.zip" sparkle:edSignature="PASTE" length="12345" type="application/octet-stream" />
   </item>
   ```
   Paste `edSignature` and `length` from `dist/sparkle-signature.txt`. The enclosure URL must be the GitHub download for that tag, and the file must be named `MapLock.zip`.
3. On GitHub, open [github.com/oiwdis/map-lock/releases/new](https://github.com/oiwdis/map-lock/releases/new).
4. Make a new tag like `v1.3.0`, add a title and a few notes about what changed. See `CHANGELOG.md`.
5. Drag `dist/MapLock.zip` into the files box. Keep the name exactly `MapLock.zip` so the appcast link works.
6. Click **Publish release**. The appcast item can be pushed before or after the release is published. Sparkle only offers the update once both the item is on `main` and the zip is downloadable.

## If something goes wrong

- **"No Developer ID Application certificate found"**: do step 1 again and check with `security find-identity -v -p codesigning`.
- **More than one certificate found**: run `DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh`.
- **Certificate shows as "not trusted"**: download the "Developer ID - G2" intermediate certificate from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/) and double click it.
- **"Could not use the notary profile"**: do step 3 again.
- **Apple did not accept the app**: the script prints a `notarytool log` command. Run it to see why.
- **"sign_update not found"**: install Sparkle's tools so `~/SparkleTools/bin/sign_update` exists, or run `SPARKLE_BIN=/path/to/bin ./release.sh`.
- **sign_update cannot find the key**: the EdDSA private key has to be in the login keychain. Unlock the keychain and run the script again.

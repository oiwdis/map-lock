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

## Each release

1. Make the zip (pick the new version number):
   ```
   VERSION=1.0.1 ./release.sh
   ```
   It builds, signs, sends the app to Apple, waits (usually a few minutes), staples the result, and checks it.
   At the end you get `dist/MapLock.zip`.
2. On GitHub, open [github.com/oiwdis/map-lock/releases/new](https://github.com/oiwdis/map-lock/releases/new).
3. Make a new tag like `v1.0.1`, add a title and a few notes about what changed.
4. Drag `dist/MapLock.zip` into the files box. Keep the name exactly `MapLock.zip` so the download page link keeps working.
5. Click **Publish release**.

## If something goes wrong

- **"No Developer ID Application certificate found"**: do step 1 again and check with `security find-identity -v -p codesigning`.
- **More than one certificate found**: run `DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh`.
- **Certificate shows as "not trusted"**: download the "Developer ID - G2" intermediate certificate from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/) and double click it.
- **"Could not use the notary profile"**: do step 3 again.
- **Apple did not accept the app**: the script prints a `notarytool log` command. Run it to see why.

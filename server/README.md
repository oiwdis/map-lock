# map-lock-api

Cloudflare Worker for Map Lock accounts, friends, stat sync, and live races. It is separate from the site worker that serves `map-lock.elliot-7c9.workers.dev`. This folder does not deploy anything by itself.

The Mac app is `com.elliot.maplock`, signed with Developer ID and no extra entitlements. Sign in with Apple uses the web flow and the Services ID `com.elliot.maplock.web` (`APPLE_WEB_CLIENT_ID`). The worker checks Apple's identity token against `https://appleid.apple.com/auth/keys`. No client secret and no `.p8` key are used.

The worker then issues its own session token. Only a SHA-256 hash of that token is stored. The app keeps the token in the Keychain and never stores the password. A password account stores the username and a PBKDF2-SHA256 hash (`iterations$salt$hash`, 100,000 iterations, a random 16-byte salt). An Apple account stores the Apple user id (`sub`) and the chosen username, with no password hash. Email is never requested or stored.

## Sign in with Apple

In the Apple Developer account (team `5225T54S66`):

1. The primary App ID stays `com.elliot.maplock`. Native Sign in with Apple is not used on the Mac build.
2. Create a Services ID with identifier `com.elliot.maplock.web`.
3. Enable Sign in with Apple on that Services ID and group it with the primary App ID `com.elliot.maplock`.
4. Register the domain `map-lock.elliot-7c9.workers.dev`.
5. Register the return URL `https://map-lock.elliot-7c9.workers.dev/v1/auth/apple/callback`.

The app opens `GET /v1/auth/apple/start`. Apple posts the identity token to that return URL. The worker redirects the browser to `maplock://auth` with a one-time code, and the app exchanges it at `POST /v1/auth/exchange`. The session token is never put in the URL.

## What you need

- Node.js 22 or newer
- A Cloudflare account
- Wrangler logged in (`npx wrangler login`)

## Deploy

From this `server/` directory:

1. Install dependencies: `npm install`
2. Create the database: `npx wrangler d1 create map-lock-api`
3. Paste the printed database id into `database_id` in `wrangler.toml`.
4. Apply the schema on a new database:

   ```
   npx wrangler d1 execute map-lock-api --remote --file=schema.sql
   ```

   If this database already exists, do not run `schema.sql` again. Apply only a migration that database does not have yet.

   `migrations/0001_initial.sql` is the original tables. Production already has them.
   `migrations/0002_password_accounts.sql` adds `password_hash` (null for Apple users), rebuilds `users` so `apple_sub` can be null, and creates `login_attempts`. Production already has that. Running it on a database created from the current `schema.sql` fails, because those columns are already there.
   `migrations/0003_race_subject_style.sql` adds `races.subject` and `races.style`. It is already applied on production. SQLite has no `ADD COLUMN IF NOT EXISTS`, so running 0003 again fails. Do not run it on prod.
   `migrations/0004_race_status.sql` adds `races.status` (`open` by default). It is already applied on production. SQLite has no `ADD COLUMN IF NOT EXISTS`, so running it again fails. Do not run it on prod.
   `migrations/0005_race_invites.sql` creates `race_invites`. It is not on production yet. Run it once. Do not edit it after that.
   `migrations/0006_race_results.sql` creates `race_results`. It is not on production yet. Run it once. Do not edit it after that.
   `migrations/0007_race_countries.sql` adds `races.countries` for a custom set. It is not on production yet. Run it once. Do not run it twice.

   Applying 0001 through 0007 builds the same database as `schema.sql`.

5. Check the project: `npm run check`
6. Deploy: `npx wrangler deploy`

No secrets are required. Apple's public keys are fetched at runtime. Do not put an Apple private key in this worker.

## Routes

`PUBLIC_ORIGIN` is `https://map-lock.elliot-7c9.workers.dev`, so race links look like `https://map-lock.elliot-7c9.workers.dev/race/<code>`. The app also calls `/v1/...` on that origin.

The existing site worker still owns that hostname. Add routes so these paths reach **map-lock-api** instead of the site worker:

- `map-lock.elliot-7c9.workers.dev/v1*`
- `map-lock.elliot-7c9.workers.dev/race/*`
- `map-lock.elliot-7c9.workers.dev/health`

In the Cloudflare dashboard that is Workers → map-lock-api → Settings → Domains & Routes, or a route in `wrangler.toml` once the zone is on your account. Leave the rest of the hostname on the site worker.

For local development, run `npx wrangler dev` and point the app at it with the UserDefaults key `maplock.apiBase` (for example `http://127.0.0.1:8787`). Local D1 needs the schema too:

```
npx wrangler d1 execute map-lock-api --local --file=schema.sql
```

## API

Session header: `Authorization: Bearer <token>`.

- `GET /v1/auth/apple/start?state=…&nonce=…` redirects to Apple. `POST /v1/auth/apple/callback` verifies the form `id_token` (`aud` is `APPLE_WEB_CLIENT_ID`) and redirects to `maplock://auth?code=…&state=…`. `POST /v1/auth/exchange` with `{ "code", "state" }` returns `{ token, user }`.
- `POST /v1/auth/apple` with `{ "identityToken", "nonce" }` still accepts a native identity token (`aud` is `com.elliot.maplock`). The Mac app does not call it.
- `POST /v1/auth/register` with `{ "username", "password" }` creates a password account. The username rules match `POST /v1/me/username`, and the username must be unique. The password is 8 to 200 characters. The response is `{ token, user }` and `needsUsername` is false.
- `POST /v1/auth/login` with `{ "username", "password" }` returns the same session shape. A wrong username, a wrong password, an Apple-only account, and a rate limit all return `Wrong username or password`. Failed attempts are limited to 10 per username and 10 per IP in 15 minutes.
- `POST /v1/me/username` with `{ "username" }`. 3 to 20 characters: letters, numbers, underscores. Rejects reserved names and a small profanity list.
- `GET /v1/me`
- `GET /v1/friends`, `POST /v1/friends/requests`, `POST /v1/friends/requests/:id/accept`, `POST /v1/friends/requests/:id/decline`, `DELETE /v1/friends/:userId`
- `GET /v1/leaderboard?region=Africa` (also Asia, Europe, North America, South America, world). Friends plus you, fastest speedrun first.
- `GET /v1/users/:username/stats` for an accepted friend only.
- `GET /v1/me/stats` and `PUT /v1/me/stats`. The body is `{ quizzes, speedruns, speedrunBests, countries }`. The worker unions history by id and keeps the faster best time for each region.
- `POST /v1/races` with `{ "region" }`. Returns `code`, `seed`, `webUrl`, and `appUrl` (`maplock://race/<code>`).
- `DELETE /v1/races/:code` cancels a race. Only the creator can do it, and only before someone else joins. Joining a cancelled code returns `This race was cancelled`.
- `POST /v1/races/:code/join`
- `GET /v1/races/:code/ws` upgrades to a WebSocket on the `RaceRoom` Durable Object.

The race page at `/race/<code>` tells people to open Map Lock or download it. It does not show stats.

## Live race

Both players connect to the Durable Object. Each sends `{ "type": "ready", "total" }`. When both are ready there is a 3-2-1 countdown, then the same `seed`. The app sorts the region's countries and shuffles them with that seed, so both maps use one order.

Progress messages are `{ "type": "progress", "found", "total", "misses", "finished" }`. The first finish wins. The official time is measured on the server from the start of the race. `{ "type": "forfeit" }` gives the other player the win. If a player drops during the countdown or the race and does not reconnect within 20 seconds, they forfeit. `{ "type": "rematch" }` from both players starts a new seed with the same two players.

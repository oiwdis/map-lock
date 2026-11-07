# map-lock-api

Cloudflare Worker for Map Lock accounts, friends, stat sync, and live races. It is separate from the site worker that serves `map-lock.elliot-7c9.workers.dev`. This folder does not deploy anything by itself.

The app bundle id is `com.elliot.maplock`. Sign in with Apple identity tokens are checked against Apple's JWKS (`https://appleid.apple.com/auth/keys`). The token audience must be that bundle id and the issuer must be `https://appleid.apple.com`. Team ID `5225T54S66` is the Apple Developer team for the app; Apple's identity token does not include the team id, so the worker binds the token to the app with the audience check.

The worker then issues its own session token. Only a SHA-256 hash of that token is stored. The app keeps the token in the Keychain. Stored profile data is the Apple user id (`sub`) and the chosen username. Email is never read into the database.

## What you need

- Node.js 22 or newer
- A Cloudflare account
- Wrangler logged in (`npx wrangler login`)

## Deploy

From this `server/` directory:

1. Install dependencies: `npm install`
2. Create the database: `npx wrangler d1 create map-lock-api`
3. Paste the printed database id into `database_id` in `wrangler.toml`.
4. Apply the schema:

   ```
   npx wrangler d1 execute map-lock-api --remote --file=schema.sql
   ```

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

- `POST /v1/auth/apple` with `{ "identityToken", "nonce" }`. Returns `{ token, user }`.
- `POST /v1/me/username` with `{ "username" }`. 3 to 20 characters: letters, numbers, underscores. Rejects reserved names and a small profanity list.
- `GET /v1/me`
- `GET /v1/friends`, `POST /v1/friends/requests`, `POST /v1/friends/requests/:id/accept`, `POST /v1/friends/requests/:id/decline`, `DELETE /v1/friends/:userId`
- `GET /v1/leaderboard?region=Africa` (also Asia, Europe, North America, South America, world). Friends plus you, fastest speedrun first.
- `GET /v1/users/:username/stats` for an accepted friend only.
- `GET /v1/me/stats` and `PUT /v1/me/stats`. The body is `{ quizzes, speedruns, speedrunBests, countries }`. The worker unions history by id and keeps the faster best time for each region.
- `POST /v1/races` with `{ "region" }`. Returns `code`, `seed`, `webUrl`, and `appUrl` (`maplock://race/<code>`).
- `POST /v1/races/:code/join`
- `GET /v1/races/:code/ws` upgrades to a WebSocket on the `RaceRoom` Durable Object.

The race page at `/race/<code>` tells people to open Map Lock or download it. It does not show stats.

## Live race

Both players connect to the Durable Object. Each sends `{ "type": "ready", "total" }`. When both are ready there is a 3-2-1 countdown, then the same `seed`. The app sorts the region's countries and shuffles them with that seed, so both maps use one order.

Progress messages are `{ "type": "progress", "found", "total", "misses", "finished" }`. The first finish wins. The official time is measured on the server from the start of the race. `{ "type": "forfeit" }` gives the other player the win. If a player drops during the countdown or the race and does not reconnect within 20 seconds, they forfeit. `{ "type": "rematch" }` from both players starts a new seed with the same two players.

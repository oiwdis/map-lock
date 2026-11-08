# Map Lock site worker

This is the worker named **map-lock**. It serves `https://map-lock.elliot-7c9.workers.dev` (the marketing page, the demo, and images). It is not `map-lock-api`.

The homepage badge is filled on the server. The worker reads the first `sparkle:shortVersionString` in `https://raw.githubusercontent.com/oiwdis/map-lock/main/appcast.xml`. If that fails, it reads `https://api.github.com/repos/oiwdis/map-lock/releases/latest`. A good answer is cached for 10 minutes (`caches.default`, and `cf.cacheTtl` on the fetch). The HTML is rewritten with `HTMLRewriter` before it is sent, so the badge does not flash. If both feeds fail, it uses the last cached version, then `1.3.3`.

`/v1`, `/race/`, and `/health` are unchanged: the worker still returns `env.API.fetch(req)` for those paths and does nothing else with them. `get-map-lock.*` still redirects to this host. The demo, `w50.json`, and images are the same bytes as before.

## File to deploy

`site/map-lock-site.js` is the whole worker: one ES module. No npm build is required to deploy that file. `node site/build.mjs` only matters if you change `site/version.js` and need to splice it in again.

## Bindings

Keep the binding that is already on **map-lock**:

| Name | Type | Service |
|---|---|---|
| `API` | service | `map-lock-api` |

Do not copy the API worker's D1 database or Durable Object onto this worker. Do not deploy this file as `map-lock-api`.

## Cloudflare API

Account `7c91f249b4af636a59808b9768fb46a7`. Script name `map-lock`.

`metadata.json`:

```json
{
  "main_module": "worker.js",
  "compatibility_date": "2026-11-07",
  "bindings": [
    { "type": "service", "name": "API", "service": "map-lock-api" }
  ]
}
```

Upload (this replaces the script and keeps the service binding):

```bash
curl -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/7c91f249b4af636a59808b9768fb46a7/workers/scripts/map-lock" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -F 'metadata=@metadata.json;type=application/json' \
  -F 'worker.js=@site/map-lock-site.js;type=application/javascript+module'
```

The token needs Workers Scripts Write. After it returns `"success": true`, open `/` and confirm the badge. `/health` should still be `{"ok":true}` and `/v1/me` should still be `{"error":"Sign in required"}`.

Leave the workers.dev subdomain on. There are no zone routes on this script; the API paths are the `API` binding above. Do not delete that binding.

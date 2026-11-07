import { verifyAppleIdentityToken } from "./apple";
import { createSession, randomCode, randomSeed, userFromRequest, type SessionUser } from "./auth";
import { canonicalBestKey, emptyPayload, isRegion, mergePayload, parsePayload } from "./merge";
import { RaceRoom } from "./race";
import { canonicalUsername, usernameProblem } from "./username";

export { RaceRoom };

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      console.log(JSON.stringify({ event: "request_error", message: error instanceof Error ? error.message : "unknown" }));
      return json({ error: "Something went wrong" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });

  const racePage = url.pathname.match(/^\/race\/([A-Za-z0-9]{4,16})$/);
  if (request.method === "GET" && racePage) return raceHtml(env, racePage[1]);

  const ws = url.pathname.match(/^\/v1\/races\/([A-Za-z0-9]{4,16})\/ws$/);
  if (ws) return raceSocket(request, env, ws[1]);

  if (!url.pathname.startsWith("/v1/")) return json({ error: "Not found" }, 404);

  if (request.method === "POST" && url.pathname === "/v1/auth/apple") return authApple(request, env);

  const user = await userFromRequest(request, env.DB);
  if (!user) return json({ error: "Sign in required" }, 401);

  if (request.method === "GET" && url.pathname === "/v1/me") return json({ user: publicUser(user) });
  if (request.method === "POST" && url.pathname === "/v1/me/username") return setUsername(request, env, user);
  if (request.method === "GET" && url.pathname === "/v1/me/stats") return getStats(env, user.id);
  if (request.method === "PUT" && url.pathname === "/v1/me/stats") return putStats(request, env, user);
  if (request.method === "GET" && url.pathname === "/v1/friends") return listFriends(env, user.id);
  if (request.method === "POST" && url.pathname === "/v1/friends/requests") return requestFriend(request, env, user);
  if (request.method === "GET" && url.pathname === "/v1/leaderboard") return leaderboard(url, env, user.id);
  if (request.method === "POST" && url.pathname === "/v1/races") return createRace(request, env, user);

  const decision = url.pathname.match(/^\/v1\/friends\/requests\/([^/]+)\/(accept|decline)$/);
  if (request.method === "POST" && decision) return decideFriend(env, user.id, decision[1], decision[2] === "accept");

  const remove = url.pathname.match(/^\/v1\/friends\/([^/]+)$/);
  if (request.method === "DELETE" && remove) return removeFriend(env, user.id, remove[1]);

  const friendStats = url.pathname.match(/^\/v1\/users\/([^/]+)\/stats$/);
  if (request.method === "GET" && friendStats) return friendSnapshot(env, user.id, decodeURIComponent(friendStats[1]));

  const join = url.pathname.match(/^\/v1\/races\/([A-Za-z0-9]{4,16})\/join$/);
  if (request.method === "POST" && join) return joinRace(env, user, join[1]);

  return json({ error: "Not found" }, 404);
}

async function authApple(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  const identityToken = stringField(body, "identityToken");
  const nonce = stringField(body, "nonce");
  if (!identityToken) return json({ error: "Missing identity token" }, 400);
  let sub: string;
  try {
    const claims = await verifyAppleIdentityToken(identityToken, env.APPLE_AUDIENCE, nonce);
    sub = claims.sub;
  } catch (error) {
    console.log(JSON.stringify({ event: "apple_auth_failed", message: error instanceof Error ? error.message : "unknown" }));
    return json({ error: "Apple sign-in was rejected" }, 401);
  }
  const existing = await env.DB.prepare(
    "SELECT id, username FROM users WHERE apple_sub = ?",
  ).bind(sub).first<{ id: string; username: string | null }>();
  let userId = existing?.id;
  let username = existing?.username ?? null;
  if (!userId) {
    userId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO users (id, apple_sub, username, username_lower, created_at) VALUES (?, ?, NULL, NULL, ?)",
    ).bind(userId, sub, Date.now()).run();
  }
  const token = await createSession(env.DB, userId);
  return json({
    token,
    user: { id: userId, username, needsUsername: !username },
  });
}

async function setUsername(request: Request, env: Env, user: SessionUser): Promise<Response> {
  const body = await readJson(request);
  const raw = stringField(body, "username") ?? "";
  const problem = usernameProblem(raw);
  if (problem) return json({ error: usernameMessage(problem) }, 400);
  const username = canonicalUsername(raw);
  const lower = username.toLowerCase();
  const taken = await env.DB.prepare(
    "SELECT id FROM users WHERE username_lower = ? AND id != ?",
  ).bind(lower, user.id).first();
  if (taken) return json({ error: "That username is taken" }, 409);
  await env.DB.prepare(
    "UPDATE users SET username = ?, username_lower = ? WHERE id = ?",
  ).bind(username, lower, user.id).run();
  return json({ user: { id: user.id, username, needsUsername: false } });
}

async function getStats(env: Env, userId: string): Promise<Response> {
  const payload = await loadPayload(env, userId);
  return json({ stats: payload });
}

async function putStats(request: Request, env: Env, user: SessionUser): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const incoming = parsePayload(await readJson(request));
  const stored = await loadPayload(env, user.id);
  const merged = mergePayload(stored, incoming);
  await env.DB.prepare(
    `INSERT INTO stat_snapshots (user_id, payload, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at`,
  ).bind(user.id, JSON.stringify(merged), Date.now()).run();
  return json({ stats: merged });
}

async function listFriends(env: Env, userId: string): Promise<Response> {
  const rows = await env.DB.prepare(
    `SELECT friendships.id AS id, friendships.status AS status, friendships.requester_id AS requesterId,
            users.id AS otherId, users.username AS username
     FROM friendships
     JOIN users ON users.id = CASE WHEN friendships.requester_id = ? THEN friendships.addressee_id ELSE friendships.requester_id END
     WHERE friendships.requester_id = ? OR friendships.addressee_id = ?`,
  ).bind(userId, userId, userId).all<{
    id: string; status: string; requesterId: string; otherId: string; username: string | null;
  }>();
  const friends = [];
  const incoming = [];
  const outgoing = [];
  for (const row of rows.results ?? []) {
    const item = { id: row.id, userId: row.otherId, username: row.username };
    if (row.status === "accepted") friends.push(item);
    else if (row.status === "pending" && row.requesterId === userId) outgoing.push(item);
    else if (row.status === "pending") incoming.push(item);
  }
  return json({ friends, incoming, outgoing });
}

async function requestFriend(request: Request, env: Env, user: SessionUser): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const body = await readJson(request);
  const wanted = (stringField(body, "username") ?? "").trim().toLowerCase();
  if (!wanted) return json({ error: "Enter a username" }, 400);
  const other = await env.DB.prepare(
    "SELECT id, username FROM users WHERE username_lower = ?",
  ).bind(wanted).first<{ id: string; username: string }>();
  if (!other) return json({ error: "No player with that username" }, 404);
  if (other.id === user.id) return json({ error: "You cannot add yourself" }, 400);
  const existing = await env.DB.prepare(
    `SELECT id, status, requester_id FROM friendships
     WHERE (requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?)`,
  ).bind(user.id, other.id, other.id, user.id).first<{ id: string; status: string; requester_id: string }>();
  if (existing?.status === "accepted") return json({ error: "You are already friends" }, 409);
  if (existing?.status === "pending") return json({ error: "A request is already waiting" }, 409);
  if (existing?.status === "declined") {
    await env.DB.prepare(
      "UPDATE friendships SET requester_id = ?, addressee_id = ?, status = 'pending', created_at = ? WHERE id = ?",
    ).bind(user.id, other.id, Date.now(), existing.id).run();
    return json({ ok: true, id: existing.id });
  }
  const id = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO friendships (id, requester_id, addressee_id, status, created_at) VALUES (?, ?, ?, 'pending', ?)",
  ).bind(id, user.id, other.id, Date.now()).run();
  return json({ ok: true, id });
}

async function decideFriend(env: Env, userId: string, requestId: string, accept: boolean): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT id FROM friendships WHERE id = ? AND addressee_id = ? AND status = 'pending'",
  ).bind(requestId, userId).first();
  if (!row) return json({ error: "That request is not waiting for you" }, 404);
  await env.DB.prepare("UPDATE friendships SET status = ? WHERE id = ?").bind(accept ? "accepted" : "declined", requestId).run();
  return json({ ok: true });
}

async function removeFriend(env: Env, userId: string, otherId: string): Promise<Response> {
  await env.DB.prepare(
    `DELETE FROM friendships
     WHERE (requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?)`,
  ).bind(userId, otherId, otherId, userId).run();
  return json({ ok: true });
}

async function leaderboard(url: URL, env: Env, userId: string): Promise<Response> {
  const requested = url.searchParams.get("key") ?? url.searchParams.get("region") ?? "world";
  const key = canonicalBestKey(requested);
  if (!key) return json({ error: "Unknown speedrun" }, 400);
  const ids = await friendIds(env, userId);
  ids.push(userId);
  const rows = [];
  for (const id of ids) {
    const person = await env.DB.prepare("SELECT id, username FROM users WHERE id = ?").bind(id).first<{ id: string; username: string | null }>();
    if (!person?.username) continue;
    const payload = await loadPayload(env, id);
    const time = payload.speedrunBests[key];
    rows.push({
      userId: person.id,
      username: person.username,
      you: person.id === userId,
      time: typeof time === "number" ? time : null,
    });
  }
  rows.sort((a, b) => {
    if (a.time === null && b.time === null) return a.username.localeCompare(b.username);
    if (a.time === null) return 1;
    if (b.time === null) return -1;
    return a.time - b.time;
  });
  return json({ region: key, rows });
}

async function friendSnapshot(env: Env, userId: string, username: string): Promise<Response> {
  const other = await env.DB.prepare(
    "SELECT id, username FROM users WHERE username_lower = ?",
  ).bind(username.trim().toLowerCase()).first<{ id: string; username: string }>();
  if (!other) return json({ error: "Not available" }, 404);
  const allowed = await env.DB.prepare(
    `SELECT id FROM friendships WHERE status = 'accepted'
     AND ((requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?))`,
  ).bind(userId, other.id, other.id, userId).first();
  if (!allowed) return json({ error: "Not available" }, 404);
  return json({ username: other.username, stats: await loadPayload(env, other.id) });
}

async function createRace(request: Request, env: Env, user: SessionUser): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const body = await readJson(request);
  const region = stringField(body, "region") ?? "";
  const subject = stringField(body, "subject") ?? "countries";
  const style = stringField(body, "style") ?? "click";
  if (!isRegion(region)) return json({ error: "Unknown region" }, 400);
  if (!["countries", "capitals", "flags"].includes(subject)) return json({ error: "Unknown type" }, 400);
  if (!["choice", "type", "click"].includes(style)) return json({ error: "Unknown answer method" }, 400);
  const code = randomCode();
  const seed = randomSeed();
  await env.DB.prepare(
    "INSERT INTO races (code, host_id, region, subject, style, seed, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).bind(code, user.id, region, subject, style, seed, Date.now()).run();
  const room = env.RACE.get(env.RACE.idFromName(code));
  await room.fetch("https://race/init", {
    method: "POST",
    body: JSON.stringify({ code, region, seed, hostId: user.id }),
  });
  return json(raceLinks(env, code, region, seed, subject, style));
}

async function joinRace(env: Env, user: SessionUser, code: string): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const race = await env.DB.prepare(
    "SELECT code, region, subject, style, seed, host_id FROM races WHERE code = ?",
  ).bind(code).first<{ code: string; region: string; subject: string; style: string; seed: string; host_id: string }>();
  if (!race) return json({ error: "Unknown race" }, 404);
  return json(raceLinks(env, race.code, race.region, race.seed, race.subject, race.style));
}

async function raceSocket(request: Request, env: Env, code: string): Promise<Response> {
  if (request.headers.get("Upgrade") !== "websocket") return json({ error: "Expected WebSocket" }, 426);
  const user = await userFromRequest(request, env.DB);
  if (!user?.username) return json({ error: "Sign in required" }, 401);
  const race = await env.DB.prepare("SELECT code FROM races WHERE code = ?").bind(code).first();
  if (!race) return json({ error: "Unknown race" }, 404);
  const headers = new Headers(request.headers);
  headers.set("x-user-id", user.id);
  headers.set("x-username", user.username);
  const stub = env.RACE.get(env.RACE.idFromName(code));
  return stub.fetch(new Request(request.url, { method: request.method, headers }));
}

function raceLinks(env: Env, code: string, region: string, seed: string, subject = "countries", style = "click") {
  const origin = env.PUBLIC_ORIGIN.replace(/\/$/, "");
  return {
    code,
    region,
    seed,
    subject,
    style,
    webUrl: `${origin}/race/${code}`,
    appUrl: `maplock://race/${code}`,
  };
}

function raceHtml(env: Env, code: string): Response {
  const safe = code.replace(/[^A-Za-z0-9]/g, "");
  const appUrl = `maplock://race/${safe}`;
  const download = "https://github.com/oiwdis/map-lock/releases/latest";
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Map Lock race ${safe}</title>
  <style>
    body { margin: 0; font: 17px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; background: #f4f7fb; color: #142033; }
    main { max-width: 34rem; margin: 8vh auto; padding: 2rem; background: white; border-radius: 18px; box-shadow: 0 12px 40px rgba(20,32,51,.08); }
    h1 { font-size: 1.8rem; margin: 0 0 .4rem; }
    p { color: #4b5b73; }
    a.button { display: inline-block; margin: .4rem .6rem .4rem 0; padding: .7rem 1rem; border-radius: 999px; background: #1f6feb; color: white; text-decoration: none; font-weight: 650; }
    a.secondary { background: #e8eef8; color: #142033; }
    code { font-family: ui-monospace, SFMono-Regular, monospace; }
  </style>
</head>
<body>
  <main>
    <h1>Map Lock race</h1>
    <p>Code <code>${safe}</code>. Open this race in Map Lock. Both players see the same countries and race live.</p>
    <p><a class="button" href="${appUrl}">Open in Map Lock</a>
       <a class="button secondary" href="${download}">Download Map Lock</a></p>
    <p>If the button does nothing, install Map Lock, then come back and choose Open in Map Lock. The app link is <code>${appUrl}</code>.</p>
  </main>
</body>
</html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

async function loadPayload(env: Env, userId: string) {
  const row = await env.DB.prepare("SELECT payload FROM stat_snapshots WHERE user_id = ?").bind(userId).first<{ payload: string }>();
  if (!row) return emptyPayload();
  try {
    return parsePayload(JSON.parse(row.payload));
  } catch {
    return emptyPayload();
  }
}

async function friendIds(env: Env, userId: string): Promise<string[]> {
  const rows = await env.DB.prepare(
    `SELECT CASE WHEN requester_id = ? THEN addressee_id ELSE requester_id END AS id
     FROM friendships WHERE status = 'accepted' AND (requester_id = ? OR addressee_id = ?)`,
  ).bind(userId, userId, userId).all<{ id: string }>();
  return (rows.results ?? []).map((row) => row.id);
}

function publicUser(user: SessionUser) {
  return { id: user.id, username: user.username, needsUsername: !user.username };
}

function usernameMessage(problem: string): string {
  switch (problem) {
    case "length": return "Usernames are 3 to 20 characters";
    case "characters": return "Use letters, numbers, and underscores only";
    case "reserved": return "That username is reserved";
    default: return "Pick a different username";
  }
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (text.length > 1_000_000) throw new Error("body too large");
  if (!text) return {};
  return JSON.parse(text);
}

function stringField(body: unknown, key: string): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const value = (body as Record<string, unknown>)[key];
  return typeof value === "string" ? value : undefined;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

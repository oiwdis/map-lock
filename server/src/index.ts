import { verifyAppleIdentityToken } from "./apple";
import { createSession, randomCode, randomSeed, randomToken, sha256Hex, userFromRequest, type SessionUser } from "./auth";
import { canonicalBestKey, emptyPayload, isRegion, mergePayload, parsePayload } from "./merge";
import { RaceRoom } from "./race";
import { clientIp, hashPassword, loginIsLimited, recordLoginFailure, verifyPassword } from "./password";
import { planFriendRequest } from "./friends";
import { RACE_INVITE_TTL_MS, RACE_UNAVAILABLE, planInviteAccept } from "./invites";
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

  if (request.method === "GET" && url.pathname === "/v1/auth/apple/start") return appleStart(url, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/apple/callback") return appleCallback(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/exchange") return exchangeAuth(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/apple") return authApple(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/register") return registerAccount(request, env);
  if (request.method === "POST" && url.pathname === "/v1/auth/login") return loginAccount(request, env);

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
  if (request.method === "GET" && url.pathname === "/v1/race-invites") return listRaceInvites(env, user);
  if (request.method === "GET" && url.pathname === "/v1/me/race-results") return listRaceResults(env, user);

  const inviteDecision = url.pathname.match(/^\/v1\/race-invites\/([^/]+)\/(accept|decline)$/);
  if (request.method === "POST" && inviteDecision) {
    return inviteDecision[2] === "accept"
      ? acceptRaceInvite(env, user, inviteDecision[1])
      : declineRaceInvite(env, user, inviteDecision[1]);
  }

  const inviteCreate = url.pathname.match(/^\/v1\/races\/([A-Za-z0-9]{4,16})\/invites$/);
  if (request.method === "POST" && inviteCreate) return createRaceInvite(request, env, user, inviteCreate[1]);

  const decision = url.pathname.match(/^\/v1\/friends\/requests\/([^/]+)\/(accept|decline)$/);
  if (request.method === "POST" && decision) return decideFriend(env, user.id, decision[1], decision[2] === "accept");

  const remove = url.pathname.match(/^\/v1\/friends\/([^/]+)$/);
  if (request.method === "DELETE" && remove) return removeFriend(env, user.id, remove[1]);

  const friendStats = url.pathname.match(/^\/v1\/users\/([^/]+)\/stats$/);
  if (request.method === "GET" && friendStats) return friendSnapshot(env, user.id, decodeURIComponent(friendStats[1]));

  const join = url.pathname.match(/^\/v1\/races\/([A-Za-z0-9]{4,16})\/join$/);
  if (request.method === "POST" && join) return joinRace(env, user, join[1]);

  const cancel = url.pathname.match(/^\/v1\/races\/([A-Za-z0-9]{4,16})$/);
  if (request.method === "DELETE" && cancel) return cancelRace(env, user, cancel[1]);

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

async function appleStart(url: URL, env: Env): Promise<Response> {
  const state = url.searchParams.get("state") ?? "";
  const nonce = url.searchParams.get("nonce") ?? "";
  if (!/^[A-Za-z0-9._-]{8,200}$/.test(state) || !/^[A-Za-z0-9._-]{8,200}$/.test(nonce)) {
    return json({ error: "Missing state or nonce" }, 400);
  }
  const now = Date.now();
  await env.DB.prepare("DELETE FROM apple_logins WHERE created_at < ?").bind(now - 10 * 60 * 1000).run();
  await env.DB.prepare(
    `INSERT INTO apple_logins (state, nonce, created_at) VALUES (?, ?, ?)
     ON CONFLICT(state) DO UPDATE SET nonce = excluded.nonce, created_at = excluded.created_at`,
  ).bind(state, nonce, now).run();
  const redirectUri = `${env.PUBLIC_ORIGIN.replace(/\/$/, "")}/v1/auth/apple/callback`;
  const authorize = new URL("https://appleid.apple.com/auth/authorize");
  authorize.searchParams.set("client_id", env.APPLE_WEB_CLIENT_ID);
  authorize.searchParams.set("redirect_uri", redirectUri);
  authorize.searchParams.set("response_type", "code id_token");
  authorize.searchParams.set("response_mode", "form_post");
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("nonce", nonce);
  return Response.redirect(authorize.toString(), 302);
}

async function appleCallback(request: Request, env: Env): Promise<Response> {
  const form = new URLSearchParams(await request.text());
  const idToken = form.get("id_token") ?? "";
  const state = form.get("state") ?? "";
  const pending = await env.DB.prepare(
    "SELECT nonce, created_at FROM apple_logins WHERE state = ?",
  ).bind(state).first<{ nonce: string; created_at: number }>();
  await env.DB.prepare("DELETE FROM apple_logins WHERE state = ?").bind(state).run();
  if (!pending || Date.now() - pending.created_at > 10 * 60 * 1000) {
    return signInPage("That sign-in expired. Close this window and try again in Map Lock.");
  }
  let sub: string;
  try {
    const claims = await verifyAppleIdentityToken(idToken, env.APPLE_WEB_CLIENT_ID, pending.nonce);
    sub = claims.sub;
  } catch (error) {
    console.log(JSON.stringify({ event: "apple_web_auth_failed", message: error instanceof Error ? error.message : "unknown" }));
    return signInPage("Apple didn't accept that sign-in. Close this window and try again in Map Lock.");
  }
  const existing = await env.DB.prepare(
    "SELECT id FROM users WHERE apple_sub = ?",
  ).bind(sub).first<{ id: string }>();
  let userId = existing?.id;
  if (!userId) {
    userId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO users (id, apple_sub, username, username_lower, created_at) VALUES (?, ?, NULL, NULL, ?)",
    ).bind(userId, sub, Date.now()).run();
  }
  const code = randomToken();
  const codeHash = await sha256Hex(code);
  await env.DB.prepare("DELETE FROM auth_codes WHERE expires_at < ?").bind(Date.now()).run();
  await env.DB.prepare(
    "INSERT INTO auth_codes (code_hash, user_id, state, expires_at) VALUES (?, ?, ?, ?)",
  ).bind(codeHash, userId, state, Date.now() + 2 * 60 * 1000).run();
  const location = `maplock://auth?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`;
  return new Response(null, { status: 302, headers: { Location: location } });
}

async function exchangeAuth(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  const code = stringField(body, "code") ?? "";
  const state = stringField(body, "state") ?? "";
  if (!code || !state) return json({ error: "That sign-in code has expired. Try again." }, 401);
  const codeHash = await sha256Hex(code);
  const row = await env.DB.prepare(
    "SELECT user_id, state, expires_at FROM auth_codes WHERE code_hash = ?",
  ).bind(codeHash).first<{ user_id: string; state: string; expires_at: number }>();
  await env.DB.prepare("DELETE FROM auth_codes WHERE code_hash = ?").bind(codeHash).run();
  if (!row || row.expires_at < Date.now() || row.state !== state) {
    return json({ error: "That sign-in code has expired. Try again." }, 401);
  }
  const person = await env.DB.prepare(
    "SELECT id, username FROM users WHERE id = ?",
  ).bind(row.user_id).first<{ id: string; username: string | null }>();
  if (!person) return json({ error: "That sign-in code has expired. Try again." }, 401);
  const token = await createSession(env.DB, person.id);
  return json({
    token,
    user: { id: person.id, username: person.username, needsUsername: !person.username },
  });
}

function signInPage(message: string): Response {
  const safe = message.replace(/[&<>"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[char] ?? char));
  return new Response(`<!doctype html><html><body style="font:16px -apple-system,sans-serif;padding:2rem"><p>${safe}</p></body></html>`, {
    status: 400,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

const WRONG_PASSWORD = "Wrong username or password";

async function registerAccount(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  const rawName = stringField(body, "username") ?? "";
  const password = stringField(body, "password") ?? "";
  const problem = usernameProblem(rawName);
  if (problem) return json({ error: usernameMessage(problem) }, 400);
  if (password.length < 8 || password.length > 200) {
    return json({ error: "Passwords must be 8 to 200 characters" }, 400);
  }
  const username = canonicalUsername(rawName);
  const lower = username.toLowerCase();
  const taken = await env.DB.prepare(
    "SELECT id FROM users WHERE username_lower = ?",
  ).bind(lower).first();
  if (taken) return json({ error: "That username is taken" }, 409);
  const userId = crypto.randomUUID();
  const passwordHash = await hashPassword(password);
  try {
    await env.DB.prepare(
      "INSERT INTO users (id, apple_sub, username, username_lower, password_hash, created_at) VALUES (?, NULL, ?, ?, ?, ?)",
    ).bind(userId, username, lower, passwordHash, Date.now()).run();
  } catch (error) {
    const text = error instanceof Error ? error.message : "";
    if (text.toLowerCase().includes("unique")) return json({ error: "That username is taken" }, 409);
    throw error;
  }
  const token = await createSession(env.DB, userId);
  return json({
    token,
    user: { id: userId, username, needsUsername: false },
  });
}

async function loginAccount(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  const rawName = stringField(body, "username") ?? "";
  const password = stringField(body, "password") ?? "";
  const lower = rawName.trim().toLowerCase().slice(0, 64);
  const ip = clientIp(request);
  const limited = await loginIsLimited(env.DB, lower, ip);
  const person = lower
    ? await env.DB.prepare(
      "SELECT id, username, password_hash FROM users WHERE username_lower = ?",
    ).bind(lower).first<{ id: string; username: string | null; password_hash: string | null }>()
    : null;
  const passwordOk = password.length >= 8 && password.length <= 200
    ? await verifyPassword(password, person?.password_hash ?? null)
    : await verifyPassword("invalid", null);
  if (limited || !person?.password_hash || !passwordOk) {
    await recordLoginFailure(env.DB, lower, ip);
    return json({ error: WRONG_PASSWORD }, 401);
  }
  const token = await createSession(env.DB, person.id);
  return json({
    token,
    user: { id: person.id, username: person.username, needsUsername: !person.username },
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
  const plan = planFriendRequest(existing, user.id);
  if (plan.action === "error") return json({ error: plan.error }, plan.status);
  if (plan.action === "accept") {
    await env.DB.prepare("UPDATE friendships SET status = 'accepted' WHERE id = ?").bind(plan.id).run();
    return json({ ok: true, id: plan.id, status: "accepted", username: other.username });
  }
  if (plan.action === "reopen") {
    await env.DB.prepare(
      "UPDATE friendships SET requester_id = ?, addressee_id = ?, status = 'pending', created_at = ? WHERE id = ?",
    ).bind(user.id, other.id, Date.now(), plan.id).run();
    return json({ ok: true, id: plan.id, status: "pending", username: other.username });
  }
  const id = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO friendships (id, requester_id, addressee_id, status, created_at) VALUES (?, ?, ?, 'pending', ?)",
  ).bind(id, user.id, other.id, Date.now()).run();
  return json({ ok: true, id, status: "pending", username: other.username });
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
    body: JSON.stringify({ code, region, seed, hostId: user.id, subject, style }),
  });
  return json(raceLinks(env, code, region, seed, subject, style));
}

async function joinRace(env: Env, user: SessionUser, code: string): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const race = await env.DB.prepare(
    "SELECT code, region, subject, style, seed, host_id, status FROM races WHERE code = ?",
  ).bind(code).first<{ code: string; region: string; subject: string; style: string; seed: string; host_id: string; status: string }>();
  if (!race) return json({ error: "Unknown race" }, 404);
  if (race.status === "cancelled") return json({ error: "This race was cancelled" }, 409);
  if (race.status !== "open") return json({ error: RACE_UNAVAILABLE }, 409);
  if (user.id !== race.host_id) await markRaceJoined(env, race.code, user.id);
  return json(raceLinks(env, race.code, race.region, race.seed, race.subject, race.style));
}

async function cancelRace(env: Env, user: SessionUser, code: string): Promise<Response> {
  const race = await env.DB.prepare(
    "SELECT code, host_id, status FROM races WHERE code = ?",
  ).bind(code).first<{ code: string; host_id: string; status: string }>();
  if (!race) return json({ error: "Unknown race" }, 404);
  if (race.host_id !== user.id) return json({ error: "Only the person who created this race can cancel it" }, 403);
  if (race.status === "cancelled") return json({ error: "This race was cancelled" }, 409);
  const room = env.RACE.get(env.RACE.idFromName(code));
  const closed = await room.fetch("https://race/cancel", {
    method: "POST",
    body: JSON.stringify({ hostId: user.id }),
  });
  if (!closed.ok) {
    const body = await closed.json().catch(() => ({ error: "Someone has already joined" }));
    const message = typeof body === "object" && body && "error" in body && typeof body.error === "string"
      ? body.error
      : "Someone has already joined";
    return json({ error: message }, closed.status === 409 ? 409 : 409);
  }
  await env.DB.prepare("UPDATE races SET status = 'cancelled' WHERE code = ?").bind(code).run();
  await env.DB.prepare(
    "UPDATE race_invites SET status = 'expired' WHERE race_code = ? AND status = 'pending'",
  ).bind(code).run();
  return json({ ok: true });
}

async function markRaceJoined(env: Env, code: string, userId: string): Promise<void> {
  await env.DB.prepare("UPDATE races SET status = 'started' WHERE code = ? AND status = 'open'").bind(code).run();
  await env.DB.prepare(
    "UPDATE race_invites SET status = 'accepted' WHERE race_code = ? AND to_user = ? AND status = 'pending'",
  ).bind(code, userId).run();
  await env.DB.prepare(
    "UPDATE race_invites SET status = 'expired' WHERE race_code = ? AND status = 'pending'",
  ).bind(code).run();
}

async function createRaceInvite(request: Request, env: Env, user: SessionUser, code: string): Promise<Response> {
  if (!user.username) return json({ error: "Pick a username first" }, 400);
  const body = await readJson(request);
  const wanted = (stringField(body, "username") ?? "").trim().toLowerCase();
  if (!wanted) return json({ error: "Enter a username" }, 400);
  const race = await env.DB.prepare(
    "SELECT code, host_id, region, status, created_at FROM races WHERE code = ?",
  ).bind(code).first<{ code: string; host_id: string; region: string; status: string; created_at: number }>();
  if (!race) return json({ error: "Unknown race" }, 404);
  if (race.host_id !== user.id) return json({ error: "Only the person who created this race can invite" }, 403);
  if (race.status !== "open") return json({ error: RACE_UNAVAILABLE }, 409);
  const other = await env.DB.prepare(
    "SELECT id, username FROM users WHERE username_lower = ?",
  ).bind(wanted).first<{ id: string; username: string }>();
  if (!other) return json({ error: "No player with that username" }, 404);
  if (other.id === user.id) return json({ error: "You cannot add yourself" }, 400);
  const friends = await env.DB.prepare(
    `SELECT id FROM friendships WHERE status = 'accepted'
     AND ((requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?))`,
  ).bind(user.id, other.id, other.id, user.id).first();
  if (!friends) return json({ error: "You can only invite a friend" }, 403);
  const existing = await env.DB.prepare(
    "SELECT id FROM race_invites WHERE race_code = ? AND to_user = ? AND status = 'pending'",
  ).bind(code, other.id).first<{ id: string }>();
  if (existing) return json({ ok: true, id: existing.id, username: other.username, region: race.region });
  const id = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO race_invites (id, race_code, from_user, to_user, created_at, status) VALUES (?, ?, ?, ?, ?, 'pending')",
  ).bind(id, code, user.id, other.id, Date.now()).run();
  return json({ ok: true, id, username: other.username, region: race.region });
}

async function listRaceResults(env: Env, user: SessionUser): Promise<Response> {
  const rows = await env.DB.prepare(
    `SELECT code, region, subject, style, finished_at AS finishedAt, payload
     FROM race_results
     WHERE player_a = ? OR player_b = ?
     ORDER BY finished_at DESC
     LIMIT 20`,
  ).bind(user.id, user.id).all<{
    code: string;
    region: string;
    subject: string;
    style: string;
    finishedAt: number;
    payload: string;
  }>();
  const results = (rows.results ?? []).map((row) => {
    let payload: unknown = null;
    try { payload = JSON.parse(row.payload); } catch { payload = null; }
    return {
      code: row.code,
      region: row.region,
      subject: row.subject,
      style: row.style,
      finishedAt: row.finishedAt,
      race: payload,
    };
  });
  return json({ results });
}

async function listRaceInvites(env: Env, user: SessionUser): Promise<Response> {
  const cutoff = Date.now() - RACE_INVITE_TTL_MS;
  await env.DB.prepare(
    "UPDATE race_invites SET status = 'expired' WHERE to_user = ? AND status = 'pending' AND created_at < ?",
  ).bind(user.id, cutoff).run();
  await env.DB.prepare(
    `UPDATE race_invites SET status = 'expired'
     WHERE to_user = ? AND status = 'pending'
       AND race_code IN (SELECT code FROM races WHERE status != 'open')`,
  ).bind(user.id).run();
  const rows = await env.DB.prepare(
    `SELECT race_invites.id AS id, race_invites.race_code AS raceCode, race_invites.created_at AS createdAt,
            users.id AS fromUserId, users.username AS fromUsername,
            races.region AS region, races.subject AS subject, races.style AS style
     FROM race_invites
     JOIN users ON users.id = race_invites.from_user
     JOIN races ON races.code = race_invites.race_code
     WHERE race_invites.to_user = ? AND race_invites.status = 'pending' AND races.status = 'open'
     ORDER BY race_invites.created_at DESC`,
  ).bind(user.id).all<{
    id: string;
    raceCode: string;
    createdAt: number;
    fromUserId: string;
    fromUsername: string | null;
    region: string;
    subject: string;
    style: string;
  }>();
  const invites = (rows.results ?? []).filter((row) => row.fromUsername).map((row) => ({
    id: row.id,
    raceCode: row.raceCode,
    createdAt: row.createdAt,
    fromUserId: row.fromUserId,
    fromUsername: row.fromUsername,
    region: row.region,
    subject: row.subject,
    style: row.style,
  }));
  return json({ invites });
}

async function acceptRaceInvite(env: Env, user: SessionUser, id: string): Promise<Response> {
  const invite = await env.DB.prepare(
    `SELECT race_invites.status AS status, race_invites.created_at AS createdAt, race_invites.race_code AS raceCode,
            races.status AS raceStatus
     FROM race_invites
     JOIN races ON races.code = race_invites.race_code
     WHERE race_invites.id = ? AND race_invites.to_user = ?`,
  ).bind(id, user.id).first<{ status: string; createdAt: number; raceCode: string; raceStatus: string }>();
  const plan = planInviteAccept(invite, invite?.raceStatus ?? null, Date.now());
  if (plan.action === "missing") return json({ error: "Unknown invite" }, 404);
  if (plan.action === "unavailable") {
    await env.DB.prepare(
      "UPDATE race_invites SET status = 'expired' WHERE id = ? AND status = 'pending'",
    ).bind(id).run();
    return json({ error: RACE_UNAVAILABLE }, 409);
  }
  return joinRace(env, user, invite!.raceCode);
}

async function declineRaceInvite(env: Env, user: SessionUser, id: string): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT id FROM race_invites WHERE id = ? AND to_user = ?",
  ).bind(id, user.id).first();
  if (!row) return json({ error: "Unknown invite" }, 404);
  await env.DB.prepare(
    "UPDATE race_invites SET status = 'declined' WHERE id = ? AND status = 'pending'",
  ).bind(id).run();
  return json({ ok: true });
}

async function raceSocket(request: Request, env: Env, code: string): Promise<Response> {
  if (request.headers.get("Upgrade") !== "websocket") return json({ error: "Expected WebSocket" }, 426);
  const user = await userFromRequest(request, env.DB);
  if (!user?.username) return json({ error: "Sign in required" }, 401);
  const race = await env.DB.prepare("SELECT code, status FROM races WHERE code = ?").bind(code).first<{ code: string; status: string }>();
  if (!race) return json({ error: "Unknown race" }, 404);
  if (race.status === "cancelled") return json({ error: "This race was cancelled" }, 409);
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

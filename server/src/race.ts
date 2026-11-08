import { DurableObject } from "cloudflare:workers";
import { lockFinish, nextAlarm, stepRace, type RaceReason } from "./raceRules";

const COUNTDOWN_STEP_MS = 1_000;

export interface RacePlayer {
  userId: string;
  username: string;
  connected: boolean;
  ready: boolean;
  found: number;
  total: number;
  misses: number;
  skips: number;
  finished: boolean;
  /** Server clock from the start, before penalties. */
  raw: number | null;
  /** Final time: raw + misses * 3s + skips * 10s. Null until they finish. */
  elapsed: number | null;
  finishedAt: number | null;
  forfeited: boolean;
  /** Still going when the race closed. */
  dnf: boolean;
  /** Finished, then left the waiting screen. The result still counts. */
  left: boolean;
  disconnectedAt: number | null;
  wantsRematch: boolean;
}

export interface RaceState {
  code: string;
  region: string;
  subject: string;
  style: string;
  seed: string;
  hostId: string;
  phase: "waiting" | "countdown" | "racing" | "finished" | "cancelled";
  countdown: number | null;
  startedAt: number | null;
  /** When the first player locked a finish. The other player keeps going. */
  firstFinishAt: number | null;
  /** The winner is known, even if the other player is still racing. */
  decided: boolean;
  tie: boolean;
  winnerId: string | null;
  reason: RaceReason | null;
  /** Written to D1 once, when the race closes. */
  stored: boolean;
  players: RacePlayer[];
}

type ClientMessage =
  | { type: "ready"; total?: number }
  | { type: "progress"; found: number; total: number; misses: number; skips?: number; finished?: boolean }
  | { type: "forfeit" }
  | { type: "leave" }
  | { type: "rematch" };

export class RaceRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/init" && request.method === "POST") {
      const body = await request.json() as {
        code: string; region: string; seed: string; hostId: string; subject?: string; style?: string;
      };
      const existing = await this.load();
      if (!existing) {
        await this.save({
          code: body.code,
          region: body.region,
          subject: body.subject || "countries",
          style: body.style || "click",
          seed: body.seed,
          hostId: body.hostId,
          phase: "waiting",
          countdown: null,
          startedAt: null,
          firstFinishAt: null,
          decided: false,
          tie: false,
          winnerId: null,
          reason: null,
          stored: false,
          players: [],
        });
      }
      return Response.json({ ok: true });
    }

    if (url.pathname === "/cancel" && request.method === "POST") {
      const body = await request.json() as { hostId?: string };
      const state = await this.load();
      if (!state) return Response.json({ ok: true });
      if (body.hostId && body.hostId !== state.hostId) {
        return Response.json({ error: "Only the person who created this race can cancel it" }, { status: 403 });
      }
      const opponent = state.players.some((player) => player.userId !== state.hostId);
      if (opponent || state.phase === "countdown" || state.phase === "racing" || state.phase === "finished") {
        return Response.json({ error: "Someone has already joined" }, { status: 409 });
      }
      state.phase = "cancelled";
      await this.save(state);
      this.broadcast(state);
      for (const socket of this.ctx.getWebSockets()) {
        try { socket.close(1000, "cancelled"); } catch { /* already closed */ }
      }
      return Response.json({ ok: true });
    }

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    const userId = request.headers.get("x-user-id") ?? "";
    const username = request.headers.get("x-username") ?? "";
    if (!userId || !username) return new Response("Unauthorized", { status: 401 });

    const state = await this.load();
    if (!state) return new Response("Unknown race", { status: 404 });
    if (state.phase === "cancelled") return new Response("This race was cancelled", { status: 409 });
    if (!this.admit(state, userId, username)) {
      return new Response("This race already has two players", { status: 409 });
    }
    await this.save(state);

    for (const existing of this.ctx.getWebSockets(userId)) {
      try { existing.close(4000, "replaced"); } catch { /* the old socket is already going away */ }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [userId]);
    server.serializeAttachment({ userId, username });
    this.markConnected(state, userId, true);
    await this.save(state);
    this.broadcast(state);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    const attachment = ws.deserializeAttachment() as { userId?: string } | null;
    const userId = attachment?.userId;
    if (!userId) return;
    let parsed: ClientMessage;
    try {
      parsed = JSON.parse(message) as ClientMessage;
    } catch {
      return;
    }
    const state = await this.load();
    if (!state) return;
    const player = state.players.find((item) => item.userId === userId);
    if (!player) return;

    if (parsed.type === "ready" && state.phase === "waiting") {
      player.ready = true;
      if (typeof parsed.total === "number" && parsed.total > 0) player.total = parsed.total;
      if (state.players.length === 2 && state.players.every((item) => item.ready && item.connected)) {
        state.phase = "countdown";
        state.countdown = 3;
        await this.ctx.storage.setAlarm(Date.now() + COUNTDOWN_STEP_MS);
      }
    } else if (parsed.type === "progress" && state.phase === "racing" && !player.forfeited && !player.finished && !player.dnf) {
      player.found = clampCount(parsed.found);
      player.total = clampCount(parsed.total);
      player.misses = clampCount(parsed.misses);
      player.skips = clampCount(parsed.skips ?? 0);
      if (parsed.finished && player.found >= player.total && player.total > 0 && state.startedAt) {
        lockFinish(player, state.startedAt, Date.now());
        if (!state.firstFinishAt) state.firstFinishAt = player.finishedAt;
      }
      stepRace(state, Date.now());
    } else if (parsed.type === "forfeit" && (state.phase === "racing" || state.phase === "countdown")) {
      this.forfeit(state, player);
    } else if (parsed.type === "leave" && player.finished) {
      player.left = true;
    } else if (parsed.type === "rematch" && state.phase === "finished") {
      player.wantsRematch = true;
      if (state.players.length === 2 && state.players.every((item) => item.wantsRematch && item.connected)) {
        this.resetForRematch(state);
      }
    }

    await this.save(state);
    this.broadcast(state);
    await this.persist(state);
    if (state.phase === "racing") await this.armRace(state);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = ws.deserializeAttachment() as { userId?: string } | null;
    const state = await this.load();
    if (!state || !attachment?.userId) return;
    const stillOpen = this.ctx.getWebSockets(attachment.userId).some((socket) => socket !== ws);
    if (stillOpen) return;
    this.markConnected(state, attachment.userId, false);
    if (state.phase === "racing") stepRace(state, Date.now());
    await this.save(state);
    this.broadcast(state);
    await this.persist(state);
    if (state.phase === "racing" || state.phase === "countdown") await this.armRace(state);
  }

  async alarm(): Promise<void> {
    const state = await this.load();
    if (!state) return;
    const now = Date.now();

    if (state.phase === "countdown") {
      for (const player of state.players) {
        if (!player.connected && player.disconnectedAt && now - player.disconnectedAt >= 20_000) {
          this.forfeit(state, player);
          await this.save(state);
          this.broadcast(state);
          await this.persist(state);
          return;
        }
      }
    }

    if (state.phase === "countdown" && state.countdown !== null) {
      state.countdown -= 1;
      if (state.countdown <= 0) {
        state.countdown = null;
        state.phase = "racing";
        state.startedAt = now;
      } else {
        let when = now + COUNTDOWN_STEP_MS;
        for (const player of state.players) {
          if (!player.connected && player.disconnectedAt) {
            const at = player.disconnectedAt + 20_000;
            if (at > now && at < when) when = at;
          }
        }
        await this.ctx.storage.setAlarm(when);
      }
      await this.save(state);
      this.broadcast(state);
      if (state.phase === "racing") await this.armRace(state);
      return;
    }

    if (state.phase === "racing") {
      stepRace(state, now);
      await this.save(state);
      this.broadcast(state);
      await this.persist(state);
      await this.armRace(state);
    }
  }

  /** Wake for a disconnect, the 5 minute wait, the moment a time is lost, or the 10 minute cap. */
  private async armRace(state: RaceState): Promise<void> {
    const when = nextAlarm(state, Date.now());
    if (when) await this.ctx.storage.setAlarm(when);
  }

  private admit(state: RaceState, userId: string, username: string): boolean {
    const existing = state.players.find((player) => player.userId === userId);
    if (existing) {
      existing.username = username;
      existing.connected = true;
      existing.disconnectedAt = null;
      return true;
    }
    if (state.players.length >= 2) return false;
    state.players.push({
      userId,
      username,
      connected: true,
      ready: false,
      found: 0,
      total: 0,
      misses: 0,
      skips: 0,
      finished: false,
      raw: null,
      elapsed: null,
      finishedAt: null,
      forfeited: false,
      dnf: false,
      left: false,
      disconnectedAt: null,
      wantsRematch: false,
    });
    return true;
  }

  private markConnected(state: RaceState, userId: string, connected: boolean): void {
    const player = state.players.find((item) => item.userId === userId);
    if (!player) return;
    player.connected = connected;
    player.disconnectedAt = connected ? null : Date.now();
  }

  private forfeit(state: RaceState, player: RacePlayer): void {
    if (state.phase === "finished" || player.forfeited || player.finished) return;
    player.forfeited = true;
    player.finished = true;
    if (state.phase === "countdown") {
      const other = state.players.find((item) => item.userId !== player.userId && !item.forfeited);
      state.winnerId = other?.userId ?? null;
      state.tie = false;
      state.decided = true;
      state.reason = "forfeit";
      state.phase = "finished";
      state.countdown = null;
      return;
    }
    stepRace(state, Date.now());
  }

  private resetForRematch(state: RaceState): void {
    const bytes = crypto.getRandomValues(new Uint8Array(8));
    state.seed = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    state.phase = "waiting";
    state.countdown = null;
    state.startedAt = null;
    state.firstFinishAt = null;
    state.decided = false;
    state.tie = false;
    state.winnerId = null;
    state.reason = null;
    state.stored = false;
    for (const player of state.players) {
      player.ready = false;
      player.found = 0;
      player.misses = 0;
      player.skips = 0;
      player.finished = false;
      player.raw = null;
      player.elapsed = null;
      player.finishedAt = null;
      player.forfeited = false;
      player.dnf = false;
      player.left = false;
      player.wantsRematch = false;
    }
  }

  /** Save the closed race once so a player who left can read it later. */
  private async persist(state: RaceState): Promise<void> {
    if (state.phase !== "finished" || state.stored || state.players.length < 2) return;
    const payload = JSON.stringify(publicState(state));
    const [a, b] = state.players;
    try {
      await this.env.DB.prepare(
        `INSERT INTO race_results (code, region, subject, style, finished_at, player_a, player_b, payload)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(code) DO UPDATE SET
           finished_at = excluded.finished_at,
           payload = excluded.payload`,
      ).bind(state.code, state.region, state.subject, state.style, Date.now(), a.userId, b.userId, payload).run();
      state.stored = true;
      await this.save(state);
    } catch (error) {
      console.log(JSON.stringify({
        event: "race_result_store_failed",
        message: error instanceof Error ? error.message : "unknown",
      }));
    }
  }

  private broadcast(state: RaceState): void {
    const payload = JSON.stringify({ type: "state", race: publicState(state) });
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(payload);
      } catch {
        // A closing socket should not stop the others from hearing the update.
      }
    }
  }

  private async load(): Promise<RaceState | null> {
    const state = await this.ctx.storage.get<RaceState>("race");
    if (!state) return null;
    state.subject = state.subject || "countries";
    state.style = state.style || "click";
    state.firstFinishAt = state.firstFinishAt ?? null;
    state.decided = state.decided ?? false;
    state.tie = state.tie ?? false;
    state.reason = state.reason ?? null;
    state.stored = state.stored ?? false;
    for (const player of state.players) {
      player.dnf = player.dnf ?? false;
      player.left = player.left ?? false;
      player.skips = player.skips ?? 0;
    }
    return state;
  }

  private async save(state: RaceState): Promise<void> {
    await this.ctx.storage.put("race", state);
  }
}

function publicState(state: RaceState) {
  const now = Date.now();
  return {
    code: state.code,
    region: state.region,
    subject: state.subject,
    style: state.style,
    seed: state.seed,
    phase: state.phase,
    countdown: state.countdown,
    startedAt: state.startedAt,
    serverNow: now,
    firstFinishAt: state.firstFinishAt,
    decided: state.decided,
    tie: state.tie,
    winnerId: state.winnerId,
    reason: state.reason,
    players: state.players.map((player) => ({
      userId: player.userId,
      username: player.username,
      connected: player.connected,
      ready: player.ready,
      found: player.found,
      total: player.total,
      misses: player.misses,
      skips: player.skips,
      finished: player.finished,
      raw: player.raw,
      elapsed: player.elapsed,
      forfeited: player.forfeited,
      dnf: player.dnf,
      left: player.left,
      wantsRematch: player.wantsRematch,
    })),
  };
}

function clampCount(value: number): number {
  if (!Number.isFinite(value) || value < 0) return 0;
  return Math.min(Math.floor(value), 1000);
}

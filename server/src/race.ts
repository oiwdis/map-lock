import { DurableObject } from "cloudflare:workers";

const FORFEIT_AFTER_MS = 20_000;
const COUNTDOWN_STEP_MS = 1_000;
const RACE_LIMIT_MS = 10 * 60 * 1000;
const MISS_PENALTY_S = 3;
const SKIP_PENALTY_S = 10;

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
  /** Final time: raw + misses * 3s + skips * 10s. */
  elapsed: number | null;
  finishedAt: number | null;
  forfeited: boolean;
  disconnectedAt: number | null;
  wantsRematch: boolean;
}

export interface RaceState {
  code: string;
  region: string;
  seed: string;
  hostId: string;
  phase: "waiting" | "countdown" | "racing" | "finished";
  countdown: number | null;
  startedAt: number | null;
  winnerId: string | null;
  players: RacePlayer[];
}

type ClientMessage =
  | { type: "ready"; total?: number }
  | { type: "progress"; found: number; total: number; misses: number; skips?: number; finished?: boolean }
  | { type: "forfeit" }
  | { type: "rematch" };

export class RaceRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/init" && request.method === "POST") {
      const body = await request.json() as { code: string; region: string; seed: string; hostId: string };
      const existing = await this.load();
      if (!existing) {
        await this.save({
          code: body.code,
          region: body.region,
          seed: body.seed,
          hostId: body.hostId,
          phase: "waiting",
          countdown: null,
          startedAt: null,
          winnerId: null,
          players: [],
        });
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
    } else if (parsed.type === "progress" && state.phase === "racing" && !player.forfeited && !player.finished) {
      player.found = clampCount(parsed.found);
      player.total = clampCount(parsed.total);
      player.misses = clampCount(parsed.misses);
      player.skips = clampCount(parsed.skips ?? 0);
      if (parsed.finished && player.found >= player.total && player.total > 0 && state.startedAt) {
        player.finished = true;
        player.finishedAt = Date.now();
        player.raw = Math.max(0, (player.finishedAt - state.startedAt) / 1000);
        player.elapsed = player.raw + player.misses * MISS_PENALTY_S + player.skips * SKIP_PENALTY_S;
        this.awardIfBothFinished(state);
      }
    } else if (parsed.type === "forfeit" && (state.phase === "racing" || state.phase === "countdown")) {
      this.forfeit(state, player);
    } else if (parsed.type === "rematch" && state.phase === "finished") {
      player.wantsRematch = true;
      if (state.players.length === 2 && state.players.every((item) => item.wantsRematch && item.connected)) {
        this.resetForRematch(state);
      }
    }

    await this.save(state);
    this.broadcast(state);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = ws.deserializeAttachment() as { userId?: string } | null;
    const state = await this.load();
    if (!state || !attachment?.userId) return;
    const stillOpen = this.ctx.getWebSockets(attachment.userId).some((socket) => socket !== ws);
    if (stillOpen) return;
    this.markConnected(state, attachment.userId, false);
    if (state.phase === "racing" || state.phase === "countdown") {
      await this.ctx.storage.setAlarm(Date.now() + FORFEIT_AFTER_MS);
    }
    await this.save(state);
    this.broadcast(state);
  }

  async alarm(): Promise<void> {
    const state = await this.load();
    if (!state) return;
    const now = Date.now();

    if (state.phase === "countdown" && state.countdown !== null) {
      state.countdown -= 1;
      if (state.countdown <= 0) {
        state.countdown = null;
        state.phase = "racing";
        state.startedAt = now;
        await this.ctx.storage.setAlarm(now + RACE_LIMIT_MS);
      } else {
        await this.ctx.storage.setAlarm(now + COUNTDOWN_STEP_MS);
      }
      await this.save(state);
      this.broadcast(state);
      return;
    }

    if (state.phase === "racing" || state.phase === "countdown") {
      for (const player of state.players) {
        if (!player.finished && !player.connected && player.disconnectedAt && now - player.disconnectedAt >= FORFEIT_AFTER_MS) {
          this.forfeit(state, player);
        }
      }
      if (state.phase === "racing" && state.startedAt && now - state.startedAt >= RACE_LIMIT_MS) {
        this.finishByTimeout(state);
      } else if (state.phase === "racing" && state.startedAt) {
        await this.armRace(state);
      }
      await this.save(state);
      this.broadcast(state);
    }
  }

  /** Keep the 10 minute limit armed without dropping a sooner forfeit check. */
  private async armRace(state: RaceState): Promise<void> {
    if (!state.startedAt || state.phase !== "racing") return;
    const timeoutAt = state.startedAt + RACE_LIMIT_MS;
    let when = timeoutAt;
    const now = Date.now();
    for (const player of state.players) {
      if (!player.finished && !player.connected && player.disconnectedAt) {
        const at = player.disconnectedAt + FORFEIT_AFTER_MS;
        if (at > now && at < when) when = at;
      }
    }
    if (when > now) await this.ctx.storage.setAlarm(when);
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
    const other = state.players.find((item) => item.userId !== player.userId);
    state.winnerId = other?.userId ?? null;
    state.phase = "finished";
    state.countdown = null;
  }

  /** Lower final time wins. A tie goes to whoever finished earlier. */
  private awardIfBothFinished(state: RaceState): void {
    const contenders = state.players.filter((player) => !player.forfeited);
    if (contenders.length < 2 || contenders.some((player) => !player.finished)) return;
    contenders.sort((a, b) => (a.elapsed ?? Number.POSITIVE_INFINITY) - (b.elapsed ?? Number.POSITIVE_INFINITY)
      || (a.finishedAt ?? 0) - (b.finishedAt ?? 0));
    state.winnerId = contenders[0]?.userId ?? null;
    state.phase = "finished";
    state.countdown = null;
  }

  /** At 10 minutes, a finisher beats someone still going. Otherwise more countries found wins. */
  private finishByTimeout(state: RaceState): void {
    if (state.phase === "finished") return;
    const finished = state.players.filter((player) => player.finished && !player.forfeited && player.elapsed != null);
    if (finished.length > 0) {
      finished.sort((a, b) => (a.elapsed ?? 0) - (b.elapsed ?? 0));
      state.winnerId = finished[0]?.userId ?? null;
    } else {
      const ranked = state.players.filter((player) => !player.forfeited)
        .sort((a, b) => b.found - a.found || a.misses - b.misses || a.skips - b.skips);
      state.winnerId = ranked[0]?.userId ?? null;
    }
    state.phase = "finished";
    state.countdown = null;
  }

  private resetForRematch(state: RaceState): void {
    const bytes = crypto.getRandomValues(new Uint8Array(8));
    state.seed = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    state.phase = "waiting";
    state.countdown = null;
    state.startedAt = null;
    state.winnerId = null;
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
      player.wantsRematch = false;
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
    return await this.ctx.storage.get<RaceState>("race") ?? null;
  }

  private async save(state: RaceState): Promise<void> {
    await this.ctx.storage.put("race", state);
  }
}

function publicState(state: RaceState) {
  return {
    code: state.code,
    region: state.region,
    seed: state.seed,
    phase: state.phase,
    countdown: state.countdown,
    winnerId: state.winnerId,
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
      wantsRematch: player.wantsRematch,
    })),
  };
}

function clampCount(value: number): number {
  if (!Number.isFinite(value) || value < 0) return 0;
  return Math.min(Math.floor(value), 1000);
}

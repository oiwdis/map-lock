import { DurableObject } from "cloudflare:workers";
import { randomCode, randomSeed } from "./auth";
import {
  applyRematchMessage,
  closeRematchFor,
  rematchIsReady,
  rematchTally,
  type RematchPlayer,
} from "./rematch";
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
  /** Why a waiting race closed before anyone joined. */
  notice: "declined" | "expired" | null;
  noticeName: string | null;
  /** Written to D1 once, when the race closes. */
  stored: boolean;
  /** Someone left the results, so another vote must not start a lobby. */
  rematchClosed: boolean;
  /** Set when the successor row could not be written. */
  rematchError: string | null;
  /** The one race both players join. Null until every vote is in. */
  rematch: RematchTicket | null;
  players: RacePlayer[];
}

interface RematchTicket {
  code: string;
  region: string;
  seed: string;
  subject: string;
  style: string;
  countries: string[] | null;
  hostId: string;
  webUrl: string;
  appUrl: string;
}

type ClientMessage =
  | { type: "ready"; total?: number }
  | { type: "progress"; found: number; total: number; misses: number; skips?: number; finished?: boolean }
  | { type: "forfeit" }
  | { type: "leave" }
  | { type: "rematch" }
  | { type: "unrematch" };

export class RaceRoom extends DurableObject<Env> {
  /** One in-flight rematch create, so two votes cannot insert two races. */
  private rematchGate: Promise<void> | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/init" && request.method === "POST") {
      const body = await request.json() as {
        code: string; region: string; seed: string; hostId: string; subject?: string; style?: string;
        roster?: { userId?: string; username?: string }[];
      };
      const existing = await this.load();
      if (!existing) {
        const roster = Array.isArray(body.roster) ? body.roster : [];
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
          notice: null,
          noticeName: null,
          stored: false,
          rematchClosed: false,
          rematchError: null,
          rematch: null,
          players: roster.flatMap((entry) => {
            const userId = (entry.userId ?? "").trim();
            const username = (entry.username ?? "").trim();
            return userId && username ? [blankPlayer(userId, username)] : [];
          }),
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

    if (url.pathname === "/challenge-end" && request.method === "POST") {
      const body = await request.json() as { notice?: string; username?: string };
      const state = await this.load();
      if (!state) return Response.json({ ok: true, missing: true });
      if (state.phase === "cancelled") return Response.json({ ok: true });
      const opponent = state.players.some((player) => player.userId !== state.hostId);
      if (opponent || state.phase !== "waiting") {
        return Response.json({ error: "Someone has already joined" }, { status: 409 });
      }
      state.phase = "cancelled";
      state.notice = body.notice === "expired" ? "expired" : "declined";
      state.noticeName = (body.username ?? "").trim() || null;
      await this.save(state);
      this.broadcast(state);
      return Response.json({ ok: true });
    }

    if (url.pathname === "/status" && request.method === "GET") {
      const state = await this.load();
      if (!state) return Response.json({ phase: "missing", notice: null, noticeName: null });
      return Response.json({
        phase: state.phase,
        notice: state.notice,
        noticeName: state.noticeName,
      });
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
      if (state.players.length >= 2 && state.players.every((item) => item.ready && item.connected)) {
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
      if (state.phase === "finished" && !state.rematch) {
        const closed = closeRematchFor(voteSnapshot(state), userId);
        writeRematchVotes(state, closed);
      }
    } else if ((parsed.type === "rematch" || parsed.type === "unrematch") && state.phase === "finished" && !state.rematch) {
      if (state.players.some((item) => item.left || !item.connected)) {
        state.rematchClosed = true;
      } else {
        const next = applyRematchMessage(voteSnapshot(state), userId, parsed.type);
        writeRematchVotes(state, next);
      }
      if (rematchIsReady(voteSnapshot(state).players, null, state.rematchClosed)) {
        await this.save(state);
        await this.createOneRematch(state);
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
    if (state.phase === "finished" && !state.rematch) {
      const closed = closeRematchFor(voteSnapshot(state), attachment.userId);
      writeRematchVotes(state, closed);
    }
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

  /** Create the successor once. A second caller waits and reuses that race. */
  private async createOneRematch(state: RaceState): Promise<void> {
    if (state.rematch || state.rematchClosed) return;
    if (!rematchIsReady(voteSnapshot(state).players, null, false)) return;
    if (!this.rematchGate) {
      let release = () => {};
      const gate = new Promise<void>((resolve) => { release = resolve; });
      this.rematchGate = gate;
      void this.finishRematch().finally(() => {
        release();
        this.rematchGate = null;
      });
    }
    await this.rematchGate;
    const fresh = await this.load();
    if (!fresh) return;
    state.rematch = fresh.rematch;
    state.rematchError = fresh.rematchError;
    state.rematchClosed = fresh.rematchClosed;
  }

  private async finishRematch(): Promise<void> {
    try {
      const source = await this.load();
      if (!source || source.rematch || source.rematchClosed) return;
      if (!rematchIsReady(voteSnapshot(source).players, null, false)) return;
      const ticket = await this.allocateRematch(source);
      const fresh = await this.load();
      if (!fresh || fresh.rematch) return;
      if (ticket && !fresh.rematchClosed && rematchIsReady(voteSnapshot(fresh).players, null, false)) {
        fresh.rematch = ticket;
        fresh.rematchError = null;
      } else if (!ticket) {
        fresh.rematchError = "Could not start the rematch.";
      }
      await this.save(fresh);
    } catch (error) {
      console.log(JSON.stringify({
        event: "rematch_create_failed",
        message: error instanceof Error ? error.message : "unknown",
      }));
      try {
        const fresh = await this.load();
        if (!fresh || fresh.rematch) return;
        fresh.rematchError = "Could not start the rematch.";
        await this.save(fresh);
      } catch {
        // The players can vote again.
      }
    }
  }

  /** Insert one row keyed by the finished race. A unique index keeps the loser. */
  private async allocateRematch(source: RaceState): Promise<RematchTicket | null> {
    const row = await this.env.DB.prepare(
      "SELECT host_id, region, subject, style, countries FROM races WHERE code = ?",
    ).bind(source.code).first<{
      host_id: string; region: string; subject: string; style: string; countries: string | null;
    }>();
    if (!row) return null;
    const minted = randomCode();
    const seed = randomSeed();
    let code = minted;
    let usedSeed = seed;
    try {
      await this.env.DB.prepare(
        `INSERT INTO races (code, host_id, region, subject, style, seed, created_at, countries, status, rematch_of)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'started', ?)`,
      ).bind(
        minted, row.host_id, row.region, row.subject, row.style, seed, Date.now(), row.countries, source.code,
      ).run();
    } catch (error) {
      const existing = await this.findRematch(source.code);
      if (!existing) {
        console.log(JSON.stringify({
          event: "rematch_create_failed",
          message: error instanceof Error ? error.message : "unknown",
        }));
        return null;
      }
      code = existing.code;
      usedSeed = existing.seed;
    }
    const ticket = this.rematchTicket(code, usedSeed, row);
    await this.initRematchRoom(ticket, source.players);
    return ticket;
  }

  private async findRematch(sourceCode: string): Promise<{ code: string; seed: string } | null> {
    try {
      const row = await this.env.DB.prepare(
        "SELECT code, seed FROM races WHERE rematch_of = ?",
      ).bind(sourceCode).first<{ code: string; seed: string }>();
      return row ?? null;
    } catch {
      return null;
    }
  }

  private rematchTicket(
    code: string,
    seed: string,
    row: { host_id: string; region: string; subject: string; style: string; countries: string | null },
  ): RematchTicket {
    const origin = this.env.PUBLIC_ORIGIN.replace(/\/$/, "");
    return {
      code,
      region: row.region,
      seed,
      subject: row.subject,
      style: row.style,
      countries: parseCountryList(row.countries),
      hostId: row.host_id,
      webUrl: `${origin}/race/${code}`,
      appUrl: `maplock://race/${code}`,
    };
  }

  private async initRematchRoom(ticket: RematchTicket, players: RacePlayer[]): Promise<void> {
    const room = this.env.RACE.get(this.env.RACE.idFromName(ticket.code));
    await room.fetch("https://race/init", {
      method: "POST",
      body: JSON.stringify({
        code: ticket.code,
        region: ticket.region,
        seed: ticket.seed,
        hostId: ticket.hostId,
        subject: ticket.subject,
        style: ticket.style,
        roster: players.map((player) => ({ userId: player.userId, username: player.username })),
      }),
    });
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
    state.notice = state.notice ?? null;
    state.noticeName = state.noticeName ?? null;
    state.stored = state.stored ?? false;
    state.rematchClosed = state.rematchClosed ?? false;
    state.rematchError = state.rematchError ?? null;
    state.rematch = state.rematch ?? null;
    for (const player of state.players) {
      player.dnf = player.dnf ?? false;
      player.left = player.left ?? false;
      player.skips = player.skips ?? 0;
      player.wantsRematch = player.wantsRematch ?? false;
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
    notice: state.notice,
    noticeName: state.noticeName,
    ...publicRematch(state),
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

function blankPlayer(userId: string, username: string): RacePlayer {
  return {
    userId,
    username,
    connected: false,
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
  };
}

function voteSnapshot(state: RaceState) {
  return {
    players: state.players.map((player) => ({
      userId: player.userId,
      connected: player.connected,
      left: player.left,
      wantsRematch: player.wantsRematch,
    })),
    closed: state.rematchClosed,
    rematchCode: state.rematch?.code ?? null,
  };
}

function writeRematchVotes(state: RaceState, next: { players: RematchPlayer[]; closed: boolean }): void {
  state.rematchClosed = next.closed || state.rematchClosed;
  for (const voted of next.players) {
    const player = state.players.find((item) => item.userId === voted.userId);
    if (!player) continue;
    player.left = voted.left;
    player.wantsRematch = voted.wantsRematch;
    if (!voted.connected) {
      player.connected = false;
      player.disconnectedAt = player.disconnectedAt ?? Date.now();
    }
  }
}

function publicRematch(state: RaceState) {
  const tally = rematchTally(state.players.map((player) => ({
    userId: player.userId,
    connected: player.connected,
    left: player.left,
    wantsRematch: player.wantsRematch,
  })));
  const dropped = state.phase === "finished" && state.players.some((player) => player.left || !player.connected);
  return {
    rematchVotes: tally.votes,
    rematchTotal: tally.total,
    rematchClosed: state.rematch ? false : state.rematchClosed || dropped,
    rematchError: state.rematchError,
    rematch: state.rematch,
  };
}

function parseCountryList(raw: string | null): string[] | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "string")) return null;
    return parsed as string[];
  } catch {
    return null;
  }
}

function clampCount(value: number): number {
  if (!Number.isFinite(value) || value < 0) return 0;
  return Math.min(Math.floor(value), 1000);
}

/*
 * Copyright (C) 2026 dauntless-nix contributors
 *
 * Licensed under the GNU Affero General Public License v3.0.
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 *
 * Client presence (dauntless-nix D41): every running game client POSTs tracking-prod/heartbeat about every 20 s with its
 * bearer token and a body naming its state and map ({ state: "menu" | "city" | "lobby" | "island", map, ping, ... }).
 * The last one per account is kept in memory for `dauntless who` and the idle auto-stop. Game servers send no player
 * token, so they are never counted. A restart forgets everything (players show up again within 20 s).
 */

export type ClientPresence = { userId: string; state: string; map: string; ping: number | undefined; lastSeenMs: number };

const Presence = new Map<string, ClientPresence>();
const MAX_ENTRIES = 10_000;
/** Three missed heartbeats. */
export const ONLINE_WINDOW_MS = 65_000;

function Text(Value: unknown, Max: number): string {
    return typeof Value === "string" ? Value.replace(/[^\x20-\x7e]/g, "").slice(0, Max) : "";
}

export function RecordClientHeartbeat(userId: string, body: unknown, nowMs: number = Date.now()): void {
    if (typeof userId !== "string" || userId.length === 0 || userId.length > 128) return;
    const Body = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
    const Ping = typeof Body.ping === "number" && Number.isFinite(Body.ping) && Body.ping >= 0 ? Math.round(Body.ping) : undefined;
    if (!Presence.has(userId) && Presence.size >= MAX_ENTRIES) PruneClientPresence(nowMs);
    Presence.set(userId, { userId, state: Text(Body.state, 32), map: Text(Body.map, 96), ping: Ping, lastSeenMs: nowMs });
}

export function PruneClientPresence(nowMs: number = Date.now()): void {
    for (const [UserId, Entry] of Presence) if (nowMs - Entry.lastSeenMs > ONLINE_WINDOW_MS) Presence.delete(UserId);
}

/** Clients heard from within the window, most recent first. */
export function OnlineClients(nowMs: number = Date.now(), withinMs: number = ONLINE_WINDOW_MS): ClientPresence[] {
    return [...Presence.values()].filter((Entry) => nowMs - Entry.lastSeenMs <= withinMs).sort((A, B) => B.lastSeenMs - A.lastSeenMs);
}

/** The latest heartbeat of any client, or undefined since the start. */
export function LastClientHeartbeatMs(): number | undefined {
    let Latest: number | undefined;
    for (const Entry of Presence.values()) if (Latest === undefined || Entry.lastSeenMs > Latest) Latest = Entry.lastSeenMs;
    return Latest;
}

export function ResetClientPresenceForTest(): void {
    Presence.clear();
}

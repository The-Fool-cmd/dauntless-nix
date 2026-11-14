/*
 * Copyright (C) 2026 dauntless-nix contributors
 *
 * Licensed under the GNU Affero General Public License v3.0.
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 *
 * Operator API (dauntless-nix D41) for the host's `dauntless` command: who is online, and live grants.
 *
 * Off unless MYSTICPARADOX_OPERATOR_TOKEN is set (then every route answers 404). Accepted only when ALL hold:
 *   - the TCP peer is loopback (the CLI on the host; nginx is loopback too, hence the next rule);
 *   - no forwarding header (X-Forwarded-*, X-Real-IP, Forwarded, Via): everything nginx proxies carries X-Forwarded-For,
 *     and the NixOS module also refuses /operator/ in nginx;
 *   - `Authorization: Bearer <token>`, compared in constant time.
 *
 *   GET  /operator/v1/who     clients heard from in the last 65 s (operator/clientPresence.ts) and the latest heartbeat
 *   POST /operator/v1/grant   { account: <name or userId>, items: { CATALOG_ID: quantity, ... } }: stacked items and
 *                             currencies, paid at once to the account's character. The game shows them after its next
 *                             inventory refresh (at the latest, the next login).
 */

import crypto from "node:crypto";
import { Request, Response, Router } from "express";
import { logger } from "../logger";
import { GetRepositories } from "../persistence";
import { IsLoopbackAddress } from "../config/proxyTrust";
import { LastClientHeartbeatMs, OnlineClients } from "../operator/clientPresence";
import { GetInventoryStoragePolicy } from "../inventoryStoragePolicy";
import { RunInventoryTransaction } from "../controllers/inventory";

export const OPERATOR_TOKEN_KEY = "MYSTICPARADOX_OPERATOR_TOKEN";
const MAX_QUANTITY = 1_000_000;
const MAX_STACKS = 50;

export const operatorRouter = Router();

function ConfiguredToken(): string | undefined {
    const Token = process.env[OPERATOR_TOKEN_KEY]?.trim();
    return Token ? Token : undefined;
}

function HasForwardingHeader(req: Request): boolean {
    return Object.keys(req.headers).some((Key) => Key.startsWith("x-forwarded-") || Key === "x-real-ip" || Key === "forwarded" || Key === "via");
}

function TokenMatches(Expected: string, Header: string | undefined): boolean {
    if (!Header || !/^bearer /i.test(Header)) return false;
    const A = crypto.createHash("sha256").update(Header.slice(7).trim()).digest();
    const B = crypto.createHash("sha256").update(Expected).digest();
    return crypto.timingSafeEqual(A, B);
}

operatorRouter.use("/operator", (req, res, next) => {
    const Expected = ConfiguredToken();
    if (Expected === undefined) { res.status(404).json({ error: "not found" }); return; }
    if (!IsLoopbackAddress(req.socket?.remoteAddress) || HasForwardingHeader(req)) {
        logger.warn(`[Operator] refused ${req.method} ${req.path}: not a direct loopback request`);
        res.status(404).json({ error: "not found" });
        return;
    }
    if (!TokenMatches(Expected, req.headers.authorization)) { res.status(401).json({ error: "operator token required" }); return; }
    next();
});

operatorRouter.get("/operator/v1/who", async (_req, res) => {
    const Now = Date.now();
    const Clients = OnlineClients(Now);
    const Online = await Promise.all(Clients.map(async (Client) => {
        const Account = await GetRepositories().launcherAccounts.findByUserId(Client.userId).catch(() => undefined);
        return {
            name: Account?.displayName ?? "?",
            userId: Client.userId,
            state: Client.state,
            map: Client.map,
            ping: Client.ping ?? null,
            secondsAgo: Math.round((Now - Client.lastSeenMs) / 1000)
        };
    }));
    const Last = LastClientHeartbeatMs();
    res.json({ online: Online, lastHeartbeatAt: Last === undefined ? null : new Date(Last).toISOString() });
});

async function FindAccount(Key: string) {
    const Repos = GetRepositories().launcherAccounts;
    return (await Repos.findByUserId(Key)) ?? (await Repos.findByDisplayNameNormalized(Key.trim().toLowerCase()));
}

/** Validates `{ CATALOG_ID: quantity }`; returns the stacks or the problems. */
export function ParseGrantItems(Raw: unknown, IsStacked: (catalogId: string) => boolean): { stacks?: Array<{ catalogId: string; quantity: number }>; problems: string[] } {
    const Problems: string[] = [];
    if (typeof Raw !== "object" || Raw === null || Array.isArray(Raw)) return { problems: ["items must be an object { CATALOG_ID: quantity }"] };
    const Entries = Object.entries(Raw as Record<string, unknown>);
    if (Entries.length === 0) Problems.push("nothing to grant");
    if (Entries.length > MAX_STACKS) Problems.push(`at most ${MAX_STACKS} items per grant`);
    for (const [Id, Quantity] of Entries) {
        if (!/^[A-Z0-9_]{1,128}$/.test(Id)) Problems.push(`bad catalog id ${JSON.stringify(Id)}`);
        else if (!IsStacked(Id)) Problems.push(`${Id} is not a known stacked item or currency (instanced items such as weapons cannot be granted)`);
        if (!Number.isInteger(Quantity) || (Quantity as number) < 1 || (Quantity as number) > MAX_QUANTITY) Problems.push(`bad quantity for ${Id} (1..${MAX_QUANTITY})`);
    }
    return Problems.length > 0 ? { problems: Problems } : { stacks: Entries.map(([catalogId, quantity]) => ({ catalogId, quantity: quantity as number })), problems: [] };
}

function IsGrantableStack(CatalogId: string): boolean {
    return GetInventoryStoragePolicy(CatalogId)?.storage === "stacked";
}

operatorRouter.post("/operator/v1/grant", async (req: Request, res: Response) => {
    const AccountKey = typeof req.body?.account === "string" ? req.body.account.trim() : "";
    if (AccountKey.length === 0 || AccountKey.length > 128) { res.status(400).json({ error: "account (name or user id) is required" }); return; }
    const Parsed = ParseGrantItems(req.body?.items, IsGrantableStack);
    if (!Parsed.stacks) { res.status(400).json({ error: Parsed.problems.join("; ") }); return; }

    const Account = await FindAccount(AccountKey);
    if (!Account) { res.status(404).json({ error: `no account named ${JSON.stringify(AccountKey)}` }); return; }
    const Characters = await GetRepositories().characters.findManyByUserId(Account.userId);
    const CharacterId = Characters[0]?.characterId;
    if (!CharacterId) { res.status(409).json({ error: `${Account.displayName} has no character yet (log in once first)` }); return; }

    const TransactionId = `operator_grant_${crypto.randomUUID()}`;
    const Applied = await RunInventoryTransaction(Account.userId, CharacterId, TransactionId, [], Parsed.stacks, [], [], [], {
        ownershipAlreadyValidated: true,
        // The Reward Cache coin is prestige-gated for players; an operator grant credits it like the tester kit does.
        operatorTestFunding: true,
        economy: { source: "OPERATOR" }
    });
    if (!Applied) {
        logger.error(`[Operator] grant to ${Account.userId} not applied (${TransactionId})`);
        res.status(500).json({ error: "the inventory transaction did not apply; see dauntless logs" });
        return;
    }
    const Summary = Parsed.stacks.map((Stack) => `${Stack.catalogId} +${Stack.quantity}`).join(", ");
    logger.info(`[Operator] grant ${Account.userId} (${Account.displayName}): ${Summary} (${TransactionId})`);
    res.json({ account: Account.displayName, userId: Account.userId, characterId: CharacterId, granted: Parsed.stacks, transactionId: TransactionId });
});

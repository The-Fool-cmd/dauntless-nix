/*
 * Copyright (C) 2026 dauntless-nix contributors
 *
 * Licensed under the GNU Affero General Public License v3.0.
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 *
 * Operator account grants (dauntless-nix D30): `account_grants.json` in the game-data directory, optional and
 * hand-written like fountain_daily_bundle.json. Applied at every launcher login, idempotently:
 *   - `entitlements`: names every account holds (premium passes, VIP, ...). Missing ones are granted; nothing is
 *     ever revoked here, so removing a name later leaves it with the accounts that already have it.
 *   - `starterCurrency` + `starterGrantId`: credited once per account. The marker entitlement
 *     `dauntless_nix_starter_<starterGrantId>` records it, in the same transaction, so a new id grants again once.
 * A broken file is logged and ignored: a login is never refused because of it.
 */

import { logger } from "./logger";
import { tryLoadGameData } from "./gameData/loader";
import { GetUnitOfWork } from "./persistence";
import { IsValidEntitlementName } from "./persistence/contracts/EntitlementRepository";
import { GrantEntitlementsInTransaction } from "./controllers/entitlements";
import { AddCurrency } from "./controllers/wallet";

export const ACCOUNT_GRANTS_FILE = "account_grants.json";
const SAFE_ID = /^[A-Za-z0-9_]+$/;

export type AccountGrants = {
    entitlements: string[];
    starterCurrency: Record<string, number>;
    starterGrantId: string;
};

/** Validates the file's content; throws with every problem listed. */
export function ParseAccountGrants(raw: any): AccountGrants {
    const Problems: string[] = [];
    const Entitlements = raw?.entitlements ?? [];
    if (!Array.isArray(Entitlements)) Problems.push("entitlements must be an array");
    else for (const Name of Entitlements) if (!IsValidEntitlementName(Name)) Problems.push(`bad entitlement name ${JSON.stringify(Name)}`);
    const Starter = raw?.starterCurrency ?? {};
    if (typeof Starter !== "object" || Array.isArray(Starter)) Problems.push("starterCurrency must be an object");
    else for (const [Id, Amount] of Object.entries(Starter)) {
        if (!/^CURRENCY_[A-Z0-9_]+$/.test(Id)) Problems.push(`bad currency id ${JSON.stringify(Id)}`);
        if (!Number.isInteger(Amount) || (Amount as number) <= 0 || (Amount as number) > 1_000_000) Problems.push(`bad amount for ${Id}`);
    }
    const GrantId = String(raw?.starterGrantId ?? "v1");
    if (!SAFE_ID.test(GrantId) || GrantId.length > 32) Problems.push(`bad starterGrantId ${JSON.stringify(GrantId)}`);
    if (Problems.length > 0) throw new Error(Problems.join("; "));
    return { entitlements: [...new Set<string>(Entitlements)], starterCurrency: Starter, starterGrantId: GrantId };
}

export function LoadAccountGrants(): AccountGrants | undefined {
    try {
        const Raw = tryLoadGameData(ACCOUNT_GRANTS_FILE);
        return Raw === undefined ? undefined : ParseAccountGrants(Raw);
    } catch (Err: any) {
        logger.error(`[AccountGrants] ${ACCOUNT_GRANTS_FILE} rejected, nothing granted: ${Err?.message ?? Err}`);
        return undefined;
    }
}

export function StarterMarker(grants: AccountGrants): string {
    return `dauntless_nix_starter_${grants.starterGrantId}`;
}

/** Grants what the file names to one account. Never throws. */
export async function ApplyAccountGrants(userId: string, grants: AccountGrants | undefined = LoadAccountGrants()): Promise<void> {
    if (!grants || !userId) return;
    try {
        await GetUnitOfWork().withTransaction(async (repos, session) => {
            await GrantEntitlementsInTransaction(repos, userId, grants.entitlements.map((name) => ({ name, duration: 0 })), "account_grants", session);
            const Starter = Object.entries(grants.starterCurrency);
            if (Starter.length === 0) return;
            const Marked = await GrantEntitlementsInTransaction(repos, userId, [{ name: StarterMarker(grants), duration: 0 }], "account_grants", session);
            if (Marked.length === 0) return;   // already credited
            for (const [Id, Amount] of Starter) await AddCurrency(userId, Id, Amount, session);
            logger.info(`[AccountGrants] ${userId} starter ${grants.starterGrantId}: ${Starter.map(([Id, Amount]) => `${Id} +${Amount}`).join(", ")}`);
        });
    } catch (Err: any) {
        logger.error(`[AccountGrants] ${userId}: grant failed, login continues: ${Err?.message ?? Err}`);
    }
}

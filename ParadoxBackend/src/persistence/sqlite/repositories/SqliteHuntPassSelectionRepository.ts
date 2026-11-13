/*
 * Copyright (C) 2026 dauntless-nix contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

import { HuntPassSelectionRepository } from "../../contracts/HuntPassSelectionRepository";
import { SqliteDatabase } from "../database";
import { Tables } from "../tables";

export class SqliteHuntPassSelectionRepository implements HuntPassSelectionRepository {
    constructor(private readonly db: SqliteDatabase) {}

    async get(userId: string): Promise<string | undefined> {
        return this.db.read(undefined, (c) => {
            const Doc = Tables.huntPassSelections.get(c, userId);
            return typeof Doc?.trackId === "string" ? Doc.trackId : undefined;
        });
    }

    async set(userId: string, trackId: string): Promise<void> {
        await this.db.write(undefined, (c) => {
            const Doc = { userId, trackId, updatedAt: new Date().toISOString() };
            const Previous = Tables.huntPassSelections.row(c, userId);
            if (Previous === undefined) Tables.huntPassSelections.insert(c, userId, Doc);
            else Tables.huntPassSelections.patch(c, Previous, Doc);
        });
    }
}

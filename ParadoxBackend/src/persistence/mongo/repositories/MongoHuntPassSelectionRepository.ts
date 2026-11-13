/*
 * Copyright (C) 2026 dauntless-nix contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

import { HuntPassSelectionRepository } from "../../contracts/HuntPassSelectionRepository";
import { GetMongoDb } from "../client";
import { Collections } from "../collections";

export class MongoHuntPassSelectionRepository implements HuntPassSelectionRepository {
    async get(userId: string): Promise<string | undefined> {
        const Db = await GetMongoDb();
        const Doc = await Db.collection(Collections.HuntPassSelections).findOne({ _id: { $eq: userId as any } });
        return typeof Doc?.trackId === "string" ? Doc.trackId : undefined;
    }

    async set(userId: string, trackId: string): Promise<void> {
        const Db = await GetMongoDb();
        await Db.collection(Collections.HuntPassSelections).updateOne(
            { _id: { $eq: userId as any } },
            { $set: { userId, trackId, updatedAt: new Date().toISOString() } },
            { upsert: true });
    }
}

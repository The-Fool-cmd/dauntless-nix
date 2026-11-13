/*
 * Copyright (C) 2026 dauntless-nix contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

// dauntless-nix D31: the pass each account levels (POST /huntpass/:userId from the hub, read by GET /huntpass/:userId).
// One document per account, _id = userId.
export interface HuntPassSelectionRepository {
    get(userId: string): Promise<string | undefined>;
    set(userId: string, trackId: string): Promise<void>;
}

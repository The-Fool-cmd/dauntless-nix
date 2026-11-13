#!/usr/bin/env node
/*
 * dauntless-nix: assemble raw/progression_config.source.json from CatalogExporter EXPORT_PROGRESSION output
 * (Items_Analysis/progression_1_14_7/*.jsonl) of YOUR OWN 1.14.7 install. Modified version of Mystic Paradox
 * (AGPL-3.0-only; see NOTICE.md). The result is game data: keep it out of the repository.
 *
 * Then validate/write it with the existing generator:
 *   npm run generate:progression-config -- --apply
 *
 * What it builds, per track the backend grants XP to (APPROVED_XP_PROGRESSION_TRACK_IDS):
 *   ExperienceTrack_PlayerLevel, ExperienceTrack_Weapon_*   <- experience-tracks / weapon-experience-tracks
 *   MasteryTrack_*                                          <- mastery-tracks
 *   PrestigeTrack_Weapon_* (reforge count)                  <- synthesised exactly as src/controllers/progression.ts
 *       describes them: one 0-XP requirement and prestige.xp_per_level 1, so the rank IS the progress.
 * Requirements keep the export's incremental per-rank XP (the backend sums them into cumulative curves).
 * Hunt Pass tracks are NOT built here: their tier costs/rewards are not in the client (see DECISIONS D19).
 *
 * usage: node scripts/assemble_progression_config.cjs <progression export dir> <output .json> [--dry-run]
 */
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const [ExportDir, OutFile] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const DRY = process.argv.includes("--dry-run");
if (!ExportDir || !OutFile) {
    console.error("usage: assemble_progression_config.cjs <progression export dir> <output .json> [--dry-run]");
    process.exit(64);
}

const WEAPONS = ["Axe", "ChainBlades", "Hammer", "Repeaters", "Spear", "Strikers", "Sword"];

function ReadRows(file) {
    const p = path.join(ExportDir, file);
    if (!fs.existsSync(p)) return [];
    return fs.readFileSync(p, "utf8").split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}
const Snake = (k) => k.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
function SnakeKeys(value) {
    if (Array.isArray(value)) return value.map(SnakeKeys);
    if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([k, v]) => [Snake(k), SnakeKeys(v)]));
    }
    return value;
}
function Rewards(list) {
    return (list ?? []).map((r) => {
        const s = SnakeKeys(r);
        return {
            rank_id: Number(s.rank_id),
            stacked_items: (s.stacked_items ?? []).map((i) => ({ catalog_id: i.catalog_id, quantity: Number(i.quantity ?? 1),
                                                                 priority: Number(i.priority ?? 0), hidden: Boolean(i.hidden ?? false) })),
            instanced_items: s.instanced_items ?? [],
            entitlements: s.entitlements ?? [],
        };
    });
}
function PathFromExport(row) {
    const b = row.base ?? row;
    const Requirements = (b.requirements ?? []).map((r) => ({ rank_id: Number(r.rankId), xp_required: Number(r.requiredXP) }));
    if (Requirements.length === 0) throw new Error(`${row.rowName}: no requirements in the export`);
    if (Requirements.some((r) => !Number.isFinite(r.rank_id) || !Number.isFinite(r.xp_required) || r.xp_required < 0)) {
        throw new Error(`${row.rowName}: malformed requirement`);
    }
    return {
        progression_id: b.progressionTrack || row.rowName,
        premium_gating_entitlement: b.premiumGatingEntitlement ?? "",
        requirements: Requirements,
        free_rewards: Rewards(b.freeRewards),
        premium_rewards: Rewards(b.premiumRewards),
    };
}

const ById = new Map();
for (const file of ["experience-tracks.jsonl", "weapon-experience-tracks.jsonl", "player-experience-tracks.jsonl", "mastery-tracks.jsonl"]) {
    for (const row of ReadRows(file)) {
        const P = PathFromExport(row);
        if (/^(ExperienceTrack_|MasteryTrack_)/.test(P.progression_id)) ById.set(P.progression_id, P);
    }
}
for (const w of WEAPONS) {
    ById.set(`PrestigeTrack_Weapon_${w}`, {
        progression_id: `PrestigeTrack_Weapon_${w}`,
        premium_gating_entitlement: "",
        requirements: [{ rank_id: 0, xp_required: 0 }],
        prestige: { xp_per_level: 1, free_rewards: [], premium_rewards: [] },
        free_rewards: [],
        premium_rewards: [],
        dauntless_nix_note: "synthesised: reforge count track (rank = progress), per src/controllers/progression.ts",
    });
}

const Expected = ["ExperienceTrack_PlayerLevel", "MasteryTrack_PlayerLevel", "MasteryTrack_Behemoth",
    ...WEAPONS.flatMap((w) => [`ExperienceTrack_Weapon_${w}`, `MasteryTrack_Weapon_${w}`, `PrestigeTrack_Weapon_${w}`])];
const Missing = Expected.filter((id) => !ById.has(id));
if (Missing.length) {
    console.error(`missing tracks in the export: ${Missing.join(", ")}`);
    process.exit(1);
}

const Out = { code: null, message: "OK", payload: { paths: [...ById.values()].sort((a, b) => a.progression_id.localeCompare(b.progression_id)) } };
for (const P of Out.payload.paths) {
    const Total = P.requirements.reduce((s, r) => s + r.xp_required, 0);
    console.log(`${P.progression_id.padEnd(36)} ranks=${String(P.requirements.length).padStart(3)} totalXP=${Total}`
        + ` freeRewardRanks=${P.free_rewards.filter((r) => r.stacked_items.length || r.instanced_items.length || r.entitlements.length).length}`);
}
if (DRY) { console.log(`dry run: ${Out.payload.paths.length} paths, nothing written`); process.exit(0); }
fs.mkdirSync(path.dirname(path.resolve(OutFile)), { recursive: true });
fs.writeFileSync(OutFile, JSON.stringify(Out, null, 1) + "\n");
console.log(`wrote ${Out.payload.paths.length} paths -> ${OutFile}`);

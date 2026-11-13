#!/usr/bin/env python3
"""Add a Hunt Pass path skeleton to a progression_config.json (in place; keeps a .bak).

The 1.14.7 client needs the active pass (default season43) to exist in the progression config: without it the hunt
pass component falls back to 'none', the bounty component finds no season dates and the hub drops the player
(ParadoxBackend routes/system.ts). The client does not ship tier costs or rewards; this writes the curve the live
passes used (101 ranks: rank 0 at 0 XP, then 100 XP per rank) and NO rewards. Rewards are added separately.
The backend clones this path for season44..season50 and rewrites the windows at run time.

usage: add-season-path.py <progression_config.json> [season_id ...]   (default: season43)
"""
import json, shutil, sys

def skeleton(season_id: str) -> dict:
    ranks = range(101)
    empty = lambda r: {"rank_id": r, "entitlements": [], "instanced_items": [], "stacked_items": []}
    return {
        "progression_id": season_id,
        "progression_multiplier": 1,
        "start_date": "2024-01-01T17:00:00+00:00",   # replaced at run time by the active-season window
        "end_date": "2099-01-01T16:59:59+00:00",
        "premium_gating_entitlement": f"{season_id}_premium",
        "requirements": [{"rank_id": r, "xp_required": 0 if r == 0 else 100} for r in ranks],
        "free_rewards": [empty(r) for r in ranks],
        "premium_rewards": [empty(r) for r in ranks],
        "prestige": {
            "xp_per_level": 100,
            "free_rewards": {"stacked_items": [{"catalog_id": "CURRENCY_PRESTIGE", "hidden": False, "quantity": 1}]},
            "premium_rewards": {"stacked_items": [{"catalog_id": "CURRENCY_PRESTIGE", "hidden": False, "quantity": 5}]},
        },
    }

def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path, ids = sys.argv[1], sys.argv[2:] or ["season43"]
    with open(path) as f:
        doc = json.load(f)
    paths = (doc.get("payload") or doc)["paths"]
    have = {p.get("progression_id") for p in paths}
    added = [i for i in ids if i not in have]
    if not added:
        print("nothing to add"); return
    shutil.copy2(path, path + ".bak")
    paths.extend(skeleton(i) for i in added)
    with open(path, "w") as f:
        json.dump(doc, f, indent=2); f.write("\n")
    print("added", ", ".join(added))

if __name__ == "__main__":
    main()

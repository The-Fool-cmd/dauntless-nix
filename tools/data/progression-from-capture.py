#!/usr/bin/env python3
"""Complete a progression_config.json from a live progression-config capture: Hunt Pass rewards and prestige blocks.

The 1.14.7 client enables only the hunt_pass_season_table rows season43..season50 (ParadoxBackend routes/system.ts),
and ships no tier costs or rewards for them (D24). The public capture of the live service's progression config
(EisigesEis/DauntlessEndpointDocumentation, Progression/Config.json) holds the real passes season09a..season27.
This copies a captured pass onto each target id: requirements, free and premium rewards, prestige and
progression_multiplier. The target keeps its own id, `<id>_premium` gating entitlement and dates (the backend
rewrites the windows at run time). `also_progress` links are kept only to paths the config has.
Every stacked or instanced reward must exist in the catalog export; otherwise nothing is written.

Prestige: for every non-season path whose requirements equal the captured path's (the client-exported weapon and
reforge tracks do, D24), the captured `prestige` block replaces ours. That is each weapon track's XP per prestige
level and the reforge tracks' Aetherheart (CURRENCY_PJM_PRESTIGE_FILLED) per level, which the client does not ship.
Paths whose requirements differ (the capture is from a later build: its player level has 12 ranks, 1.14.7 has 20)
are left alone and reported.

usage: progression-from-capture.py <progression_config.json> <capture Config.json> <catalog_1_14_7.jsonl> \
           target=source [target=source ...]          e.g. season43=season25 season44=season26
The config is changed in place; a .bak copy is kept.
"""
import copy, json, shutil, sys

COPIED = ("requirements", "free_rewards", "premium_rewards", "prestige", "progression_multiplier")

def reward_ids(path: dict):
    for track in ("free_rewards", "premium_rewards"):
        for rank in path.get(track, []):
            for kind in ("stacked_items", "instanced_items"):
                for item in rank.get(kind, []):
                    yield item["catalog_id"]
    for track in (path.get("prestige") or {}).values():
        if isinstance(track, dict):
            for kind in ("stacked_items", "instanced_items"):
                for item in track.get(kind, []):
                    yield item["catalog_id"]

def main(config_path: str, capture_path: str, catalog_path: str, pairs: list[str]) -> int:
    with open(catalog_path, encoding="utf-8") as f:
        catalog = {json.loads(line)["itemId"] for line in f if line.strip()}
    capture = {p["progression_id"]: p for p in json.load(open(capture_path, encoding="utf-8"))["payload"]["paths"]}
    with open(config_path, encoding="utf-8") as f:
        doc = json.load(f)
    paths = (doc.get("payload") or doc)["paths"]
    by_id = {p["progression_id"]: p for p in paths}

    problems = []
    for pair in pairs:
        target, _, source = pair.partition("=")
        if not source or source not in capture:
            problems.append(f"{pair}: no captured path {source!r}"); continue
        missing = sorted({i for i in reward_ids(capture[source]) if i not in catalog})
        if missing:
            problems.append(f"{pair}: rewards not in the catalog: {', '.join(missing)}"); continue
        src = capture[source]
        dst = by_id.get(target)
        if dst is None:
            dst = {"progression_id": target, "start_date": src["start_date"], "end_date": src["end_date"]}
            paths.append(dst); by_id[target] = dst
        for key in COPIED:
            if key in src:
                dst[key] = copy.deepcopy(src[key])
        dst["premium_gating_entitlement"] = f"{target}_premium"
        links = [l for l in src.get("also_progress", []) if l.get("progression_id") in by_id]
        if links:
            dst["also_progress"] = copy.deepcopy(links)
        else:
            dst.pop("also_progress", None)
        ranks = len(dst["requirements"])
        print(f"{target} <- {source} ({src['start_date'][:10]}): {ranks} ranks, "
              f"{sum(1 for _ in reward_ids(src))} item rewards, also_progress {[l['progression_id'] for l in links]}")

    targets = {pair.partition("=")[0] for pair in pairs}
    for pid, dst in by_id.items():
        src = capture.get(pid)
        if pid in targets or src is None or pid.startswith("season"):
            continue
        if dst.get("requirements") != src.get("requirements"):
            print(f"{pid}: requirements differ from the capture, prestige left alone"); continue
        if "prestige" in src and dst.get("prestige") != src["prestige"]:
            missing = sorted({i for i in reward_ids({"prestige": src["prestige"]}) if i not in catalog})
            if missing:
                problems.append(f"{pid}: prestige rewards not in the catalog: {', '.join(missing)}"); continue
            dst["prestige"] = copy.deepcopy(src["prestige"])
            dst.pop("dauntless_nix_note", None)
            print(f"{pid}: prestige <- capture {json.dumps(src['prestige'])[:100]}")

    if problems:
        print("nothing written:", *problems, sep="\n  ", file=sys.stderr)
        return 1
    shutil.copy2(config_path, config_path + ".bak")
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2); f.write("\n")
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 5:
        print(__doc__, file=sys.stderr); sys.exit(64)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))

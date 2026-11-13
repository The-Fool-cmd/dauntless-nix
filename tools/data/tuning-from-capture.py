#!/usr/bin/env python3
"""Write the backend's game-tuning files from the live-service capture (EisigesEis/DauntlessEndpointDocumentation).

  huntpass_xp_config.json      <- Progression/Game Tuning/GetHPXPConfig.md     (the Hunt Pass XP each activity grants)
  seasonal_event_schedule.json <- Progression/Game Tuning/GetEventSchedule.md  (events and rumours)

Each file holds the response's `payload`. The XP capture was saved with decimal commas ("1,000000000000000"); they
are turned back into points. The schedule also gets an `annual` calendar (month-day windows, UTC) for the
seasonal events, which the capture had parked in 2099, and an empty `alwaysOn` list. The backend moves each annual
event to its current or next window at run time (routes/tuning.ts, dauntless-nix D33). Edit both lists in the
written file to taste.

usage: tuning-from-capture.py <capture repo> <out dir>
"""
import json, os, re, sys

# Approximate live-service windows (UTC); three weeks unless the live event ran longer.
ANNUAL = {
    "EVENT_SAINTSBOND": ["02-06", "02-27"],
    "EVENT_SPRINGTIDE": ["04-01", "04-22"],
    "Event_Anniversary_Evergreen": ["05-19", "06-09"],
    "EVENT_DARKHARVEST": ["10-14", "11-04"],
    "EVENT_RAMSGIVING": ["11-18", "12-09"],
    "EVENT_FROSTFALL": ["12-11", "01-08"],
    "Frostfall_Snowball_Fight": ["12-11", "01-08"],
    "event_id_public_frostwolf_frostfall": ["12-11", "01-08"],
    "event_id_public_shoutout_frostfall": ["12-11", "01-08"],
}

def response(path: str, decimal_commas: bool) -> dict:
    text = open(path, encoding="utf-8").read()
    block = re.search(r"## Example Response\s*```json\s*(.*?)```", text, re.S)
    if not block:
        sys.exit(f"{path}: no example response")
    body = block.group(1)
    if decimal_commas:
        body = re.sub(r"(?<=\d),(?=\d{6,}\b)", ".", body)
    return json.loads(body)["payload"]

def main(capture: str, out: str) -> None:
    tuning = os.path.join(capture, "Progression", "Game Tuning")
    xp = response(os.path.join(tuning, "GetHPXPConfig.md"), True)
    schedule = response(os.path.join(tuning, "GetEventSchedule.md"), False)
    names = {item["Name"] for item in schedule["ScheduledItems"]}
    missing = sorted(set(ANNUAL) - names)
    if missing:
        sys.exit(f"annual events not in the schedule: {missing}")
    schedule = {"annual": ANNUAL, "alwaysOn": [], **schedule}
    for name, data in (("huntpass_xp_config.json", xp), ("seasonal_event_schedule.json", schedule)):
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2); f.write("\n")
    rules = sum(len(c.get("Rules", [])) for c in xp.get("EventConfigs", []))
    print(f"huntpass_xp_config.json: {len(xp.get('EventConfigs', []))} event configs, {rules} rules, global {xp.get('GlobalConfig')}")
    print(f"seasonal_event_schedule.json: {len(schedule['ScheduledItems'])} items, {len(ANNUAL)} on the annual calendar")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

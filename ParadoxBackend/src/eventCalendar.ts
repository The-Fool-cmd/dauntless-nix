/*
 * Copyright (C) 2026 dauntless-nix contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 *
 * dauntless-nix D33: the seasonal event schedule (GET game_tuning/seasonal_event_schedule) from the host-side
 * `seasonal_event_schedule.json` (tools/data/tuning-from-capture.py). The live service moved events by hand; here
 * each event named in `annual` ("MM-DD" start and end, UTC, 17:00) gets its current window, or its next one when
 * none is open. Every event in `alwaysOn` runs all the time. Other items are served as captured.
 */

export type ScheduleFile = {
    annual?: Record<string, [string, string]>;
    alwaysOn?: string[];
    ScheduledItems: any[];
};

const MONTH_DAY = /^(\d{2})-(\d{2})$/;
const ALWAYS_START = Date.UTC(2024, 0, 1, 17);
const ALWAYS_END = Date.UTC(2099, 0, 1, 17);

/** The client's time format: 2024.12.19-19.00.00 (UTC). */
export function FormatScheduleTime(ms: number): string {
    const D = new Date(ms);
    const P = (n: number) => String(n).padStart(2, "0");
    return `${D.getUTCFullYear()}.${P(D.getUTCMonth() + 1)}.${P(D.getUTCDate())}-${P(D.getUTCHours())}.${P(D.getUTCMinutes())}.${P(D.getUTCSeconds())}`;
}

function At(year: number, monthDay: string): number {
    const M = MONTH_DAY.exec(monthDay);
    if (!M) throw new Error(`bad month-day ${JSON.stringify(monthDay)}`);
    return Date.UTC(year, Number(M[1]) - 1, Number(M[2]), 17);
}

/** The window of an annual event that is open at `now`, or else the next one. A window may cross New Year. */
export function AnnualWindow(start: string, end: string, now: number): { start: number; end: number } {
    const Year = new Date(now).getUTCFullYear();
    for (const Y of [Year - 1, Year, Year + 1]) {
        const S = At(Y, start);
        let E = At(Y, end);
        if (E <= S) E = At(Y + 1, end);
        if (now < E) return { start: S, end: E };
    }
    throw new Error("unreachable");
}

export function ResolveSchedule(file: ScheduleFile, now: number): { ScheduledItems: any[] } {
    const Annual = file.annual ?? {};
    const AlwaysOn = new Set(file.alwaysOn ?? []);
    const Items = (file.ScheduledItems ?? []).map((Item: any) => {
        if (AlwaysOn.has(Item?.Name)) {
            return { ...Item, StartTime: FormatScheduleTime(ALWAYS_START), EndTime: FormatScheduleTime(ALWAYS_END) };
        }
        const Window = Annual[Item?.Name];
        if (!Window) return Item;
        const W = AnnualWindow(Window[0], Window[1], now);
        return { ...Item, StartTime: FormatScheduleTime(W.start), EndTime: FormatScheduleTime(W.end) };
    });
    return { ScheduledItems: Items };
}

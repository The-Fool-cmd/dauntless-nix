import test from "node:test";
import assert from "node:assert/strict";
import { AnnualWindow, FormatScheduleTime, ResolveSchedule } from "./eventCalendar";

const T = (s: string) => Date.parse(s);

test("event calendar: the open window, else the next one; windows may cross New Year (D33)", () => {
    assert.equal(FormatScheduleTime(T("2026-11-18T17:00:00Z")), "2026.11.18-17.00.00");
    const Open = AnnualWindow("11-18", "12-09", T("2026-11-20T00:00:00Z"));
    assert.equal(FormatScheduleTime(Open.start), "2026.11.18-17.00.00");
    assert.equal(FormatScheduleTime(Open.end), "2026.12.09-17.00.00");
    const Next = AnnualWindow("10-14", "11-04", T("2026-11-13T00:00:00Z"));
    assert.equal(FormatScheduleTime(Next.start), "2027.10.14-17.00.00");
    const Frost = AnnualWindow("12-11", "01-08", T("2027-01-03T00:00:00Z"));
    assert.equal(FormatScheduleTime(Frost.start), "2026.12.11-17.00.00");
    assert.equal(FormatScheduleTime(Frost.end), "2027.01.08-17.00.00");
});

test("event calendar: alwaysOn wins, unlisted items pass through untouched", () => {
    const Out = ResolveSchedule({
        annual: { A: ["11-18", "12-09"] }, alwaysOn: ["B"],
        ScheduledItems: [{ Name: "A", StartTime: "x" }, { Name: "B", StartTime: "x" }, { Name: "C", StartTime: "x", EndTime: "y" }],
    }, T("2026-11-20T00:00:00Z"));
    assert.equal(Out.ScheduledItems[0].StartTime, "2026.11.18-17.00.00");
    assert.equal(Out.ScheduledItems[1].StartTime, "2024.01.01-17.00.00");
    assert.equal(Out.ScheduledItems[1].EndTime, "2099.01.01-17.00.00");
    assert.deepEqual(Out.ScheduledItems[2], { Name: "C", StartTime: "x", EndTime: "y" });
});

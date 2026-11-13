import test from "node:test";
import assert from "node:assert/strict";
import { StatusPayload } from "./statusMessage";

test("status message: official text by default, configurable, can be hidden", () => {
    assert.equal(StatusPayload({})["en"], "Welcome to Mystic Paradox!");
    const Custom = StatusPayload({ MYSTICPARADOX_STATUS_MESSAGE: "Private server" });
    assert.equal(Custom["en"], "Private server");
    assert.equal(Custom["ja"], "Private server");
    assert.deepEqual(StatusPayload({ MYSTICPARADOX_STATUS_MESSAGE: "off" }), { "show-status": false });
});

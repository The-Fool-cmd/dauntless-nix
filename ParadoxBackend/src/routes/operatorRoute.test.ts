// dauntless-nix D41: operator API gate, grant validation and client presence.
import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import express from "express";
import { operatorRouter, ParseGrantItems, OPERATOR_TOKEN_KEY } from "./operator";
import { LastClientHeartbeatMs, OnlineClients, RecordClientHeartbeat, ResetClientPresenceForTest } from "../operator/clientPresence";

function request(port: number, path: string, headers: Record<string, string> = {}): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
        const req = http.request({ hostname: "127.0.0.1", port, path, method: "GET", headers }, (res) => {
            let body = "";
            res.setEncoding("utf8");
            res.on("data", (chunk) => { body += chunk; });
            res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
        });
        req.on("error", reject);
        req.end();
    });
}

test("operator API: off without a token; loopback, no forwarding header and the bearer token otherwise", async () => {
    const Previous = process.env[OPERATOR_TOKEN_KEY];
    const App = express();
    App.use(express.json());
    App.use(operatorRouter);
    const Server = App.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => Server.once("listening", () => resolve()));
    const Port = (Server.address() as import("node:net").AddressInfo).port;
    ResetClientPresenceForTest();
    try {
        delete process.env[OPERATOR_TOKEN_KEY];
        assert.equal((await request(Port, "/operator/v1/who", { authorization: "Bearer x" })).status, 404);

        process.env[OPERATOR_TOKEN_KEY] = "operator-test-token";
        assert.equal((await request(Port, "/operator/v1/who")).status, 401);
        assert.equal((await request(Port, "/operator/v1/who", { authorization: "Bearer wrong" })).status, 401);
        // What nginx proxies always carries X-Forwarded-For: refused even with the right token.
        assert.equal((await request(Port, "/operator/v1/who", { authorization: "Bearer operator-test-token", "x-forwarded-for": "10.77.0.3" })).status, 404);
        const Ok = await request(Port, "/operator/v1/who", { authorization: "Bearer operator-test-token" });
        assert.equal(Ok.status, 200);
        assert.deepEqual(JSON.parse(Ok.body), { online: [], lastHeartbeatAt: null });
    } finally {
        await new Promise<void>((resolve) => Server.close(() => resolve()));
        if (Previous === undefined) delete process.env[OPERATOR_TOKEN_KEY]; else process.env[OPERATOR_TOKEN_KEY] = Previous;
    }
});

test("grant items: known stacked ids and sane quantities only", () => {
    const Stacked = (Id: string) => Id === "CURRENCY_PLATINUM" || Id === "CONTAINER_CORE_GOLD_CELLCORE";
    assert.deepEqual(ParseGrantItems({ CURRENCY_PLATINUM: 500, CONTAINER_CORE_GOLD_CELLCORE: 3 }, Stacked).stacks,
        [{ catalogId: "CURRENCY_PLATINUM", quantity: 500 }, { catalogId: "CONTAINER_CORE_GOLD_CELLCORE", quantity: 3 }]);
    assert.equal(ParseGrantItems({}, Stacked).stacks, undefined);
    assert.equal(ParseGrantItems([], Stacked).stacks, undefined);
    assert.match(ParseGrantItems({ WEAPON_SWORD_X: 1 }, Stacked).problems.join(), /not a known stacked item/);
    assert.match(ParseGrantItems({ CURRENCY_PLATINUM: 0 }, Stacked).problems.join(), /bad quantity/);
    assert.match(ParseGrantItems({ CURRENCY_PLATINUM: -5 }, Stacked).problems.join(), /bad quantity/);
    assert.match(ParseGrantItems({ CURRENCY_PLATINUM: 1.5 }, Stacked).problems.join(), /bad quantity/);
    assert.match(ParseGrantItems({ "bad id": 1 }, Stacked).problems.join(), /bad catalog id/);
});

test("client presence: latest heartbeat per account, dropped after the window", () => {
    ResetClientPresenceForTest();
    RecordClientHeartbeat("a", { state: "city", map: "ramsgate_01_persistent", ping: 12.4 }, 1_000);
    RecordClientHeartbeat("b", { state: "menu", map: "Map_LoginMenu", ping: -1 }, 2_000);
    RecordClientHeartbeat("a", { state: "island", map: "adventure_moss_falls\u0000", ping: 30 }, 3_000);
    assert.deepEqual(OnlineClients(3_000).map((C) => [C.userId, C.state, C.map, C.ping]),
        [["a", "island", "adventure_moss_falls", 30], ["b", "menu", "Map_LoginMenu", undefined]]);
    assert.deepEqual(OnlineClients(2_000 + 65_001).map((C) => C.userId), ["a"]);
    assert.deepEqual(OnlineClients(3_000 + 65_001), []);
    assert.equal(LastClientHeartbeatMs(), 3_000);
    RecordClientHeartbeat("c", "not an object", 4_000);
    assert.equal(OnlineClients(4_000)[0].state, "");
});

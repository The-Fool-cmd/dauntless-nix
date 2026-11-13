import test from "node:test";
import assert from "node:assert/strict";
import { ParseAccountGrants, StarterMarker } from "./accountGrants";

test("account grants: a valid file parses, duplicates collapse, the marker carries the grant id", () => {
    const Grants = ParseAccountGrants({ entitlements: ["ent_boost_vip", "season43_premium", "ent_boost_vip"],
        starterCurrency: { CURRENCY_PLATINUM_UNIV: 500 }, starterGrantId: "plat500" });
    assert.deepEqual(Grants.entitlements, ["ent_boost_vip", "season43_premium"]);
    assert.equal(StarterMarker(Grants), "dauntless_nix_starter_plat500");
    assert.equal(ParseAccountGrants({}).starterGrantId, "v1");
});

test("account grants: every problem is reported and nothing is accepted", () => {
    assert.throws(() => ParseAccountGrants({ entitlements: ["ok", "bad name"], starterCurrency: { platinum: 5, CURRENCY_X: -1 },
        starterGrantId: "a b" }), (Err: Error) => /bad entitlement name/.test(Err.message) && /bad currency id/.test(Err.message)
        && /bad amount for CURRENCY_X/.test(Err.message) && /bad starterGrantId/.test(Err.message));
    assert.throws(() => ParseAccountGrants({ entitlements: "x" }), /must be an array/);
});

test("account grants: one-time credits name one account each, with unique ids", () => {
    const Grants = ParseAccountGrants({ credits: [{ id: "refund_1", userId: "00000000-0000-4000-8000-000000000001", currency: { CURRENCY_PLATINUM_UNIV: 150 } }] });
    assert.deepEqual(Grants.credits, [{ id: "refund_1", userId: "00000000-0000-4000-8000-000000000001", currency: { CURRENCY_PLATINUM_UNIV: 150 } }]);
    assert.deepEqual(ParseAccountGrants({}).credits, []);
    assert.throws(() => ParseAccountGrants({ credits: [
        { id: "a", userId: "u1", currency: { CURRENCY_PLATINUM_UNIV: 1 } },
        { id: "a", userId: "bad id!", currency: { platinum: 0 } },
    ] }), (Err: Error) => /duplicate credit id a/.test(Err.message) && /bad userId in credit a/.test(Err.message) && /bad currency id/.test(Err.message));
    assert.throws(() => ParseAccountGrants({ credits: {} }), /credits must be an array/);
});

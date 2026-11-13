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

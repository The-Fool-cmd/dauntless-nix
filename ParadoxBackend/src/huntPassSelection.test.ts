import test from "node:test";
import assert from "node:assert/strict";
import { IsCosmeticPassId, IsSelectablePassId } from "./controllers/progression";

test("selectable passes: the enabled seasons and the cosmetic passes, never test or other tracks (D31)", () => {
    for (const Id of ["season43", "season50", "season10a_vault", "eventpass_ragnar", "rewardcache_season15a"]) {
        assert.equal(IsSelectablePassId(Id), true, Id);
    }
    for (const Id of ["season42", "season51", "season19", "eventpass_ragnar_test", "test_minipass01", "ExperienceTrack_PlayerLevel",
        "PrestigeTrack_Weapon_Axe", "Linked_Slayer_Slot_1", "d24_season1", "season10a_vault2"]) {
        assert.equal(IsSelectablePassId(Id), false, Id);
    }
    assert.equal(IsCosmeticPassId("season43"), false);
});

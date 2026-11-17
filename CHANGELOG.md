# Changelog

## 2.0.0 (2026-11-17)

- **A resource of its own: no more whip_core edits.** Install `zext_scenario_share` and `ensure` it. WHIP updates no longer remove it.
- Opened with **/scenarioshare** (Director builders, `director.build`): a Share tab listing every scenario, and an Import tab.
- **Imports become Director templates** in the editor's New list. A builder's copy is an ordinary draft, switched off. Imports are kept in the resource's own table (`zext_scenario_share_imports`) and can be removed from the Import tab.
- Exports moved to this resource: `exports.zext_scenario_share:ImportScenarioCode(code, { name? })` (returns `{ name, problems }`) and `GetScenarioShareCode(key, rev?)`.
- The code format (`WDS1.`, `WDS0.`, `ZX-`) and the `zext_share_hub` convar are unchanged. Codes from 1.x import into 2.0 and the other way round.
- Licence: the resource is now MIT, since it contains no WHIP code. The 1.x patch stays LGPL-3.0 in its releases.
- **Untested in game yet.**

## 1.1.1 (2026-11-16)

- **Supports whip_core 1.2.0**, the latest WHIP-FX core. The three files this add-on changes are the same in whip_core 1.0.1 and 1.2.0, so the add-on itself is unchanged and works on both.
- The drop-in folder is now `whip_core-1.2.0/`, and the patch is `patch/zext-scenario-share-whip_core-1.2.0.patch`. It was checked against WHIP's own v1.2.0 files: it applies, comes back out cleanly, and every whip_core function it uses is still there.

## 1.1.0 (2026-11-15)

- **Resources can import Director creations.** New server export `ImportScenarioCode(code, opts?)` takes a short code, a long code, a scenario's JSON, or a scenario table, and makes a new switched-off scenario, with the same checks as Import code. It waits for the Director to finish loading after a restart.
- New server export `GetScenarioShareCode(key, rev?)` gives a scenario's long code (`WDS0.`) from a script.
- New convar `zext_share_hub`: the hub the server uses for short codes in scripts (`""` turns it off).
- Keys made by `ImportScenarioCode` follow the same rule as the Import code button (`courier`, then `courier_2`, `courier_3`…).
- Only `server/director/hub.lua` changed. The other two files are the same as 1.0.0.
- The README has preview images of the windows (`docs/screenshots/`).

## 1.0.0 (2026-11-15)

- First release, for whip_core 1.0.1.
- **Share code** on a scenario's page shows a long code (`WDS1.`) and can get a short code (`ZX-`) from the hub.
- **Import code** on the Scenarios list takes a short or long code and makes a new scenario that is switched off. It also lists any items or cards this server is missing.
- The community hub is at `https://zext-scenario-hub.whipshare.workers.dev`.

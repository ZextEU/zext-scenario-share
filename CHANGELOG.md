# Changelog

## 1.1.0 (2026-11-15)

- **Resources can import Director creations.** New server export `ImportScenarioCode(code, opts?)` takes a short code, a long code, a scenario's JSON, or a scenario table, and makes a new switched-off scenario, with the same checks as Import code. It waits for the Director to finish loading after a restart.
- New server export `GetScenarioShareCode(key, rev?)` gives a scenario's long code (`WDS0.`) from a script.
- New convar `zext_share_hub`: the hub the server uses for short codes in scripts (`""` turns it off).
- Only `server/director/hub.lua` changed. The other two files are the same as 1.0.0.

## 1.0.0 (2026-11-15)

- First release, for whip_core 1.0.1.
- **Share code** on a scenario's page shows a long code (`WDS1.`) and can get a short code (`ZX-`) from the hub.
- **Import code** on the Scenarios list takes a short or long code and makes a new scenario that is switched off. It also lists any items or cards this server is missing.
- The community hub is at `https://zext-scenario-hub.whipshare.workers.dev`.

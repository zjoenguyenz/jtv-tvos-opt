# Sync reference — live plugin set (for the Phase 1 audit)

This folder is a **read-only snapshot** of the production plugin repo `zjoenguyenz/jtv-source` at head `e89c0454` (plain-text staging form; on GitHub the live files are base64-wrapped). It was added to this copy repo by the leader so the audit can cross-check synchronisation without any extra repo access. Do not treat anything here as app code to optimise — it is evidence.

- **Bundled set (in the app):** `JTV/Plugins/` — 12 plugins as `<id>_plugin.js` + its own `plugins.json`. This is the cold-start / offline fallback set the app ships with.
- **Live set (this snapshot):** `sync-reference/jtv-source/plugins.json` (14 entries) + `sync-reference/jtv-source/plugins/modNN.js`. Map modNN ↔ plugin id via the live `plugins.json` (each entry names its file). The app downloads this set at runtime and prefers it when reachable.

## Audit task (add as a section of AUDIT.md)
For every plugin: compare bundled vs live — version (from each `plugins.json`), then content (normalise the file-name difference; diff the JS). Report per plugin: IN SYNC / STALE (bundled older) / MISSING IN BUNDLE / CONTENT-DIFFERS-SAME-VERSION. For each non-sync case, state the user-visible consequence when the app falls back to the bundled copy (fresh install before first sync, live fetch failure), and recommend a bundle-refresh policy (e.g. refresh the bundled set at every release round from the live set).

Leader's preliminary measurement (verify or refute — do not copy blindly): 123av bundled 1.0.5 vs live 1.0.8; missav 1.1.4 vs 1.1.7; hentaihub 1.0.2 vs 1.0.7; njav 1.0.7 vs 1.0.8; sextop1 2.0.3 vs 2.0.4; topxx 1.0.2 vs 1.0.3; javguru and javsnap absent from the bundled set entirely; avdbapi, javhd, misskon, sayhentai, torrenthub, vlxx version-equal (content still to be diffed).

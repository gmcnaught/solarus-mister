# Release test — <TAG>

**RC tag:** <v1.1.0-rc1>
**Release tag:** <v1.1.0>
**Tested commit:** <40-hex>
**RBF:** <Solarus_YYYYMMDD.rbf>
**rbf_run_id / engine_run_id:** <id> / <id>
**Device:** 192.168.20.81
**Operator:** <initials>
**Date:** <YYYY-MM-DD>

## Gate 1 — provenance + structure

```
<paste the results table from scripts/release_test.sh gate1>
```

## Gate 2 — install + boot + soak

```
<paste the results table from scripts/release_test.sh gate2>
```

**Measured title fps:** min <N> (floor 45)
**Soak:** <N> min, engine alive, frames advancing

**Master_Daemon:** stopped by Gate 2, not restarted (device needs a reboot to
get it back, or leave the Solarus daemon running via `Scripts/Solarus.sh`).

## Gate 3 — operator visual gate

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | Title screen clean (pairing canary) | | |
| 2 | OSD Load Quest boots each quest | | |
| 3 | Loading bar advances | | |
| 4 | Overworld walk clean | | |
| 5 | Dialog renders and dismisses | | |
| 6 | Save-file select / in-game menu | | |
| 7 | Define buttons, then all buttons correct | | |
| 8 | Quest switch + core reload, no wedge | | |

## Gate 4 — post-publish identity

```
<paste the results table from scripts/release_test.sh gate4>
```

## Verdict

<SHIPPED / BLOCKED — and why>

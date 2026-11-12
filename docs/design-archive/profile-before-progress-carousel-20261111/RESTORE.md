Profile before single-card progress carousel

This is the exact Profile source immediately before replacing its six-card progress grid. It includes the current Quest Board chest and all existing profile controls.

To restore only the prior progress layout, copy `_StatsGrid`, `_StatCard`, and `_LiveStat` plus the `_StatsGrid` call from this file into the current Profile source. Preserve newer unrelated changes. No data, reward, or backend migration is involved.

# AE2 CC Monitor

A touch-friendly ComputerCraft / CC:Tweaked dashboard for an Applied Energistics 2 network exposed through an Advanced Peripherals ME Bridge.

## Install

Run this on the ComputerCraft computer:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua startup.lua
reboot
```

## Navigation

The bottom row is a persistent touch navigation bar:

- **Overview** — health, storage, FE stored/trend, active crafting, and the most important alert.
- **Crafting** — active AE2 crafting jobs, progress, crafted quantity, sampled rate, ETA, CPU, bytes, and subpart information when Advanced Peripherals exposes it.
- **Stock** — confirmed material drops, recent use, ATM10 bottleneck warnings, and `IGN` controls.
- **Storage** — paged largest-item list and manual/automatic bulk-cell markers.
- **Movers** — recent item deltas sorted by movement rate, with per-minute and per-hour estimates.
- **System** — grid status, cells, drives, FE storage/trend, bridge power flow, crafting CPUs, version, and updater.
- **Tools** — one-touch AE2 diagnostic generation and optional Pastebin upload, with the latest link shown on the monitor.

Each attached monitor remembers its own selected page while the script is running.

## Crafting Detection

The monitor checks both:

1. `getCraftingTasks()` / `listCraftingTasks()`
2. Each crafting CPU's `craftingJob` field

The CPU fallback is important on Advanced Peripherals / AE2 combinations where terminal-started crafts make a CPU busy but do not appear in `getCraftingTasks()`.

Available information varies by mod version. The dashboard displays only fields the bridge actually exposes. Rate is sampled from progress changes and may show `rate learning` briefly. Subparts are shown when the crafting job exposes used, emitted, or missing-item information.

If a CPU is busy but the bridge exposes no job object, the Crafting page reports that crafting was detected while job details are unavailable instead of incorrectly claiming the system is idle.

## Readability

The interface separates dense information into focused pages instead of one long dashboard. It uses:

- A fixed high-contrast header and health strip
- Larger summary tiles
- Plain capacity bars with values and percentages
- Four-line crafting cards
- Alternating storage rows
- A persistent bottom navigation bar
- A fixed-column low-stock table with compact categories, count/target values, urgency colors, and non-overlapping paging controls

The script starts at monitor text scale `1` and falls back to `0.5` when a display would otherwise be too small for the interface.

## Update

Open **System** and tap `UPDATE`. The script downloads the latest `startup.lua` from this repository and reboots.

## Tools and diagnostic upload

Open **Tools** and tap `CREATE + UPLOAD AE2 DUMP`. The dashboard downloads the latest `ae2-dump.lua`, collects a one-shot read-only snapshot, saves `ae2-dump.txt`, uploads it to Pastebin when `.ae2_pastebin_key` exists, and displays the resulting URL and paste code. The last successful URL is saved in `.ae2_last_paste`.

Manual update:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua startup.lua
reboot
```

## Pages

The bottom navigation uses fixed-width slots so the page labels stay aligned on small monitors:

`HOME` / `CRAFT` / `STOCK` / `STORE` / `MOVE` / `SYS` / `MORE`

On wider monitors the labels expand to `OVERVIEW`, `CRAFT`, `STOCK`, `STORAGE`, `MOVERS`, `SYSTEM`, and `TOOLS`.

The `MORE` / `TOOLS` page includes the AE2 diagnostic dumper. It downloads `ae2-dump.lua` from this repository when needed and can keep the last Pastebin link on the computer.

Pastebin upload needs a local `.ae2_pastebin_key` file on the ComputerCraft computer. The key is intentionally not stored in this repository.

## Multiple Monitors

One connected monitor wall is exposed by CC:Tweaked as one large monitor. Separate attached monitors each render the dashboard and can be navigated independently.

## Bulk Cell Markers

The Storage page shows `BULK` when the script can associate an item with a bulk storage cell. Auto-detection depends on the information returned by Advanced Peripherals and may not identify the partitioned item on every pack version.

Tap `B+` to manually mark an item as bulk-backed. Tap `BULK` to remove the manual marker. Manual markers persist in `.ae2_bulk_items`.

You can also edit the file directly:

```lua
edit .ae2_bulk_items
```

Example:

```text
minecraft:cobblestone
minecraft:netherrack
iron ingot
```

## Depletion Warnings

Usage history is stored in `.ae2_usage_state`. The monitor waits for repeated confirmed count drops before raising a warning because AE2 snapshots can fluctuate during crafting, importing, or item movement.

`RECENT USE` is a softer signal based on repeated movement. Storage cells, spatial items, patterns, and similar infrastructure items are filtered to reduce false warnings.

Tap `IGN` beside a confirmed warning to ignore it. To clear learned history and ignored items:

```lua
delete .ae2_usage_state
reboot
```

## Bridge-specific Crafting Estimates

Some Advanced Peripherals builds expose terminal-started jobs only through a crafting CPU's `craftingJob` field. In that case the bridge provides the target item and quantity, but no direct completed count or percentage. The dashboard now shows **RUNNING** instead of a misleading `0%`, estimates positive output from AE2 stock changes, and clearly labels those figures as estimates.

The Crafting page also uses `getPatterns()` to show the immediate recipe inputs for the active output. Stock estimates can under-count outputs that are consumed immediately by parent recipes, or over-count items imported from elsewhere.

When `getDrives()` returns no location data, the System page reports drive data as unavailable and shows the exposed pattern count instead. Automatic bulk-item association is disabled when cell objects do not expose their configured contents; manual `B+` markers continue to work.

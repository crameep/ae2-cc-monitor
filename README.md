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

- **Overview** — health, storage, power, active crafting, and the most important alert.
- **Crafting** — active AE2 crafting jobs, progress, crafted quantity, sampled rate, ETA, CPU, bytes, and subpart information when Advanced Peripherals exposes it.
- **Stock** — confirmed material drops, recent use, ATM10 bottleneck warnings, and `IGN` controls.
- **Storage** — paged largest-item list and manual/automatic bulk-cell markers.
- **System** — grid status, cells, drives, power flow, crafting CPUs, version, and updater.

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

The script starts at monitor text scale `1` and falls back to `0.5` when a display would otherwise be too small for the interface.

## Update

Open **System** and tap `UPDATE`. The script downloads the latest `startup.lua` from this repository and reboots.

Manual update:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua startup.lua
reboot
```

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

# AE2 Diagnostic Dump

`ae2-dump.lua` creates a one-shot, paste-ready snapshot of the ComputerCraft computer and its AE2 connection.

It records:

- Every attached peripheral, peripheral type, and exposed method
- Every connected `me_bridge`
- Results from all exposed read-only-looking methods beginning with `get`, `list`, `is`, `has`, or `count`
- Errors from getter methods that require arguments, which helps identify their expected API shape
- Getter results found inside returned crafting task and crafting CPU objects
- Deep `getCraftingTask(id)` / `getCraftingJob(id)` lookups when task IDs are exposed
- Items, fluids, cells, drives, storage, energy, CPUs, tasks, and any additional data exposed by the installed mod versions

Only read-only-looking methods are invoked. Import, export, crafting, configuration, and other mutation methods are listed but not called.

## Install and run

Stop the dashboard with `Ctrl+T`, then run:

```lua
delete ae2-dump.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/ae2-dump.lua ae2-dump.lua
ae2-dump
```

The output is saved as:

```text
ae2-dump.json
```

Upload it with ComputerCraft's built-in Pastebin program:

```lua
pastebin put ae2-dump.json
```

Or generate and upload in one command:

```lua
ae2-dump upload
```

Paste the resulting Pastebin code or URL into the chat. If the dump is too large for Pastebin, upload `ae2-dump.json` directly as a file.

Afterward, restart the dashboard:

```lua
reboot
```

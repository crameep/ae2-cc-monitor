#!/usr/bin/env node
const fs = require("fs");

const file = process.argv[2] || "test/fixtures/fake-dump.json";
const dump = JSON.parse(fs.readFileSync(file, "utf8"));
const bridge = (dump.bridges || [])[0];
if (!bridge) throw new Error("missing bridge");

function probe(method) {
  return (bridge.targetedProbes || []).find((row) => row.method === method && (!row.args || row.args.length === 0));
}

function value(method) {
  const row = probe(method);
  return row && row.result && row.result.returned && row.result.returned.values
    ? row.result.returned.values[0]
    : undefined;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const stored = value("getStoredEnergy");
const capacity = value("getEnergyCapacity");
const fluids = value("getFluids");
const cells = value("getCells");

assert(typeof stored === "number" && stored > 0, "missing stored AE energy");
assert(typeof capacity === "number" && capacity >= stored, "missing AE energy capacity");
assert(Array.isArray(fluids) && fluids.length >= 1, "missing fluids array");
assert(Array.isArray(cells) && cells.length >= 1, "missing cells array");

const topFluid = fluids.slice().sort((a, b) => Number(b.count || 0) - Number(a.count || 0))[0];
const itemCells = cells.filter((cell) => cell.type === "ae2:i").length;
const fluidCells = cells.filter((cell) => cell.type === "ae2:f").length;

assert(topFluid && topFluid.name, "missing top fluid name");
assert(itemCells > 0, "missing item cells");
assert(fluidCells > 0, "missing fluid cells");

console.log(`ok energy=${Math.round(stored)}/${Math.round(capacity)} topFluid=${topFluid.name} itemCells=${itemCells} fluidCells=${fluidCells}`);

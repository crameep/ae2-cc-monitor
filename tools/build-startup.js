#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const srcDir = path.join(root, "src");
const outFile = path.join(root, "startup.lua");

const files = fs.readdirSync(srcDir)
  .filter((name) => /^\d+-.+\.lua$/.test(name))
  .sort();

if (files.length === 0) {
  throw new Error("No src/*.lua chunks found");
}

function exposeTopLevelLocals(source) {
  return source
    .replace(/^local function ([A-Za-z_][A-Za-z0-9_]*)/gm, "function $1")
    .replace(/^local ([A-Za-z_][A-Za-z0-9_]*)(\s*=.*)?$/gm, (_, name, rest) => {
      return rest ? `${name}${rest}` : `${name} = nil`;
    });
}

const body = files
  .map((name) => exposeTopLevelLocals(fs.readFileSync(path.join(srcDir, name), "utf8").replace(/\s*$/g, "")))
  .join("\n\n");

fs.writeFileSync(outFile, body + "\n");
console.log(`built startup.lua from ${files.length} chunks`);

"use strict";
/* Compares all locale .cfg files: same sections+keys, same __N__ placeholders. */
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..", "locale");
const langs = fs.readdirSync(root).filter((d) => fs.statSync(path.join(root, d)).isDirectory());

const parsed = {};
for (const lang of langs) {
  const file = path.join(root, lang, "blueprint-exporter.cfg");
  const buf = fs.readFileSync(file);
  if (buf[0] === 0xEF) console.log(`${lang}: WARNING UTF-8 BOM present`);
  const text = buf.toString("utf8");
  const map = new Map();
  let section = "";
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const s = line.match(/^\[(.+)\]$/);
    if (s) { section = s[1]; continue; }
    const eq = line.indexOf("=");
    if (eq < 0) { console.log(`${lang}: BAD LINE ${line}`); continue; }
    map.set(section + "/" + line.slice(0, eq), line.slice(eq + 1));
  }
  parsed[lang] = map;
}

let problems = 0;
for (const lang of langs) {
  const keys = new Set([...parsed.en.keys(), ...parsed[lang].keys()]);
  for (const key of keys) {
    const a = parsed.en.get(key);
    const b = parsed[lang].get(key);
    if (a === undefined) { console.log(`${lang}: EXTRA key ${key}`); problems++; continue; }
    if (b === undefined) { console.log(`${lang}: MISSING key ${key}`); problems++; continue; }
    const pa = [...a.matchAll(/__(\d+)__/g)].map((m) => m[1]).join(",");
    const pb = [...b.matchAll(/__(\d+)__/g)].map((m) => m[1]).join(",");
    if (pa !== pb) { console.log(`${lang}: placeholder mismatch ${key} en=[${pa}] ${lang}=[${pb}]`); problems++; }
  }
  console.log(`ok: ${lang} (${parsed[lang].size} keys)`);
}
console.log(problems === 0 ? "LOCALES CONSISTENT" : "PROBLEMS: " + problems);
process.exit(problems ? 1 : 0);

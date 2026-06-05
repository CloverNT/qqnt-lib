#!/usr/bin/env node
// ---------------------------------------------------------------------------
// pe_to_def.mjs <pe-file> <dll-name> <out.def>
//
// Read a PE (DLL/EXE/.node) export table and write a module-definition file:
//   LIBRARY "<dll-name>"
//   EXPORTS
//       <name>
//       ...
// Fed to MSVC `lib.exe /def:<out.def> /out:<name>.lib /machine:<X64|ARM64>` to
// produce a genuine MSVC import library. Lists named exports (what consumers
// link against by name) — works for x64 and arm64 PEs alike.
// ---------------------------------------------------------------------------
import { readFileSync, writeFileSync } from "node:fs";

const [file, dllName, outDef] = process.argv.slice(2);
if (!file || !dllName || !outDef) {
  console.error("usage: pe_to_def.mjs <pe-file> <dll-name> <out.def>");
  process.exit(2);
}

const b = readFileSync(file);
if (b.readUInt16LE(0) !== 0x5a4d) { console.error(`${file}: not a PE (no MZ)`); process.exit(1); }
const pe = b.readUInt32LE(0x3c);
if (b.readUInt32LE(pe) !== 0x00004550) { console.error(`${file}: not a PE (no PE\\0\\0)`); process.exit(1); }

const nsec = b.readUInt16LE(pe + 6);
const optSize = b.readUInt16LE(pe + 20);
const magic = b.readUInt16LE(pe + 24);                 // 0x10b PE32 / 0x20b PE32+
const ddOff = pe + 24 + (magic === 0x20b ? 112 : 96);  // data dir 0 = export table
const expRVA = b.readUInt32LE(ddOff);
const secOff = pe + 24 + optSize;

const rva2off = (rva) => {
  for (let i = 0; i < nsec; i++) {
    const s = secOff + i * 40;
    const va = b.readUInt32LE(s + 12);
    const vs = Math.max(b.readUInt32LE(s + 8), b.readUInt32LE(s + 16));
    const praw = b.readUInt32LE(s + 20);
    if (rva >= va && rva < va + vs) return rva - va + praw;
  }
  return -1;
};
const cstr = (o) => { let e = o; while (e < b.length && b[e]) e++; return b.toString("latin1", o, e); };

const names = [];
if (expRVA) {
  const e = rva2off(expRVA);
  if (e >= 0) {
    const nNames = b.readUInt32LE(e + 24);
    const namesArr = rva2off(b.readUInt32LE(e + 32));
    if (namesArr >= 0) {
      for (let i = 0; i < nNames; i++) {
        const off = rva2off(b.readUInt32LE(namesArr + i * 4));
        if (off >= 0) names.push(cstr(off));
      }
    }
  }
}

const def = `LIBRARY "${dllName}"\nEXPORTS\n` + names.map((n) => `    ${n}`).join("\n") + "\n";
writeFileSync(outDef, def);
console.log(`${dllName}: ${names.length} exports -> ${outDef}`);

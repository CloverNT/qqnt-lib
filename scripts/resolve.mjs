#!/usr/bin/env node
// ---------------------------------------------------------------------------
// resolve.mjs - Plan a "latest QQ NT" build across all four targets and decide
// whether the GitHub Release for this build already exists.
//
// Resolves the CURRENT QQ release from Tencent's official rainbow configs and
// emits, to $GITHUB_OUTPUT, the download URLs for:
//     windows x64 / arm64   (gtimg.cn, works worldwide)
//     linux   x64 / arm64   (.deb, gtimg.cn)
// plus the shared build number, per-platform version, the release tag, the four
// expected asset names, and a `skip` flag that is true when the release already
// has all four .zip assets (so a scheduled run is a no-op when nothing changed).
//
// The official configs expose only a 3-part version (no build number), so we
// read the real build cheaply by range-fetching just the .deb's control file
// (~40 KB at the front of the ar archive) instead of the ~200 MB package.
//
// Env:
//   FORCE              "true" to ignore an existing release and rebuild
//   GITHUB_REPOSITORY  owner/repo (auto-set in Actions) - used for the skip check
//   GITHUB_TOKEN       token for the release API (auto-set in Actions)
// ---------------------------------------------------------------------------

import { appendFileSync } from "node:fs";
import zlib from "node:zlib";

const WIN_CONFIG =
  "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/windowsConfig.js";
const LINUX_CONFIG =
  "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js";

const FORCE = (process.env.FORCE || "").trim().toLowerCase() === "true";

function fail(msg) {
  console.error(`::error::resolve: ${msg}`);
  process.exit(1);
}

async function fetchRetry(url, kind = "text", opts = {}, tries = 4) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, {
        headers: { "User-Agent": "qq-lib-autogen", ...(opts.headers || {}) },
      });
      if (!r.ok && r.status !== 206) throw new Error(`HTTP ${r.status}`);
      if (kind === "json") return await r.json();
      if (kind === "buffer") return Buffer.from(await r.arrayBuffer());
      return await r.text();
    } catch (e) {
      lastErr = e;
      await new Promise((res) => setTimeout(res, 600 * (i + 1)));
    }
  }
  throw new Error(`fetch failed for ${url}: ${lastErr}`);
}

// Rainbow configs: `;(function(){var params= {...};  ...})()` -> pull the JSON.
function parseRainbow(js) {
  const m = js.match(/var\s+params\s*=\s*(\{[\s\S]*?\})\s*;/);
  if (!m) throw new Error("could not parse rainbow config JSON");
  return JSON.parse(m[1]);
}

// Read the build number + linux 3-part version from a .deb's control file using
// a single small range request. Returns { build, linuxver3 } or null.
async function cheapBuild(url) {
  try {
    const buf = await fetchRetry(url, "buffer", { headers: { Range: "bytes=0-262143" } });
    if (buf.slice(0, 8).toString() !== "!<arch>\n") return null;
    let pos = 8, found = null;
    while (pos + 60 <= buf.length) {
      const name = buf.slice(pos, pos + 16).toString().trim().replace(/\/+$/, "");
      const size = parseInt(buf.slice(pos + 48, pos + 58).toString().trim(), 10);
      if (!Number.isFinite(size)) break;
      const data = pos + 60;
      if (name.startsWith("control.tar")) { found = { name, data, size }; break; }
      pos = data + size + (size % 2);
    }
    if (!found || found.data + found.size > buf.length) return null;
    const blob = buf.slice(found.data, found.data + found.size);
    let txt;
    if (found.name.endsWith(".gz")) txt = zlib.gunzipSync(blob).toString("latin1");
    else if (found.name.endsWith(".zst") && zlib.zstdDecompressSync)
      txt = zlib.zstdDecompressSync(blob).toString("latin1");
    else return null;
    const m = txt.match(/Version:\s*(\d+\.\d+\.\d+)-(\d+)/);
    return m ? { linuxver3: m[1], build: m[2] } : null;
  } catch {
    return null;
  }
}

// Asset names already attached to the release for `tag` (empty set if none).
async function releaseAssets(tag) {
  const repo = process.env.GITHUB_REPOSITORY;
  if (!repo) return new Set();
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  try {
    const r = await fetch(`https://api.github.com/repos/${repo}/releases/tags/${tag}`, {
      headers: {
        "User-Agent": "qq-lib-autogen",
        Accept: "application/vnd.github+json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    });
    if (!r.ok) return new Set();
    const rel = await r.json();
    return new Set((rel.assets || []).map((a) => a.name));
  } catch {
    return new Set();
  }
}

// --- resolve ---------------------------------------------------------------

const winCfg = parseRainbow(await fetchRetry(WIN_CONFIG));
const linCfg = parseRainbow(await fetchRetry(LINUX_CONFIG));

const out = {
  winver3: winCfg.version || "",
  update_date: winCfg.updateDate || linCfg.updateDate || "",
  win_x64_url: winCfg.ntDownloadX64Url || "",
  win_arm64_url: winCfg.ntDownloadARMUrl || "",
  linux_x64_url: linCfg.x64DownloadUrl?.deb || "",
  linux_arm64_url: linCfg.armDownloadUrl?.deb || "",
};
for (const [k, v] of Object.entries(out))
  if (!v && k.endsWith("_url")) console.error(`::warning::resolve: missing ${k} in official config`);

const probe = out.linux_x64_url ? await cheapBuild(out.linux_x64_url) : null;
out.build = probe?.build || "";
out.linuxver3 = probe?.linuxver3 || linCfg.version || "";
if (!out.build)
  fail("could not read the build number from the .deb control file; cannot name the release. Re-run later.");

// The four target SDK folders / release assets, and the per-build release tag.
const folders = [
  `qqnt-sdk-${out.winver3}-${out.build}-windows-x64`,
  `qqnt-sdk-${out.winver3}-${out.build}-windows-arm64`,
  `qqnt-sdk-${out.linuxver3}-${out.build}-linux-x64`,
  `qqnt-sdk-${out.linuxver3}-${out.build}-linux-arm64`,
];
const assets = folders.map((f) => `${f}.zip`);
out.folders = folders.join(",");
out.assets = assets.join(",");
out.tag = `qq-${out.build}`;

// Skip when the release already has a .zip for every arch slot, regardless of
// the exact version/build in each filename. This is robust to any cross-platform
// build skew (the per-platform version the build jobs detect from the binaries
// may differ from what we predicted here) - the tag qq-<build> still groups them.
const present = await releaseAssets(out.tag);
const presentZips = [...present].filter((a) => a.endsWith(".zip"));
const SLOTS = ["windows-x64", "windows-arm64", "linux-x64", "linux-arm64"];
out.existing = presentZips.join(",");
out.skip = String(!FORCE && SLOTS.every((s) => presentZips.some((a) => a.endsWith(`-${s}.zip`))));
out.force = String(FORCE);

// --- emit ------------------------------------------------------------------

const gh = process.env.GITHUB_OUTPUT;
if (gh) {
  const lines = Object.entries(out).map(([k, v]) => `${k}=${String(v).replace(/\r?\n/g, " ")}`);
  appendFileSync(gh, lines.join("\n") + "\n");
}

console.log("=== resolve (latest -> release) ===");
for (const [k, v] of Object.entries(out)) console.log(`${k}: ${v}`);

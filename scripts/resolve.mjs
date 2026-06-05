#!/usr/bin/env node
// ---------------------------------------------------------------------------
// resolve.mjs - Parse the official QQ frontend for the LATEST downloads.
//
// QQ's CDN prunes old builds, so we never pin/guess a build - we take whatever
// the official download pages currently serve (the latest, always present) and
// let the build jobs detect the exact x.x.xx-xxxxx version from the binaries.
//
// Flow: fetch the download page -> read its `rainbowConfigUrl` -> fetch that
// config -> read the gtimg download URLs for windows x64/arm64 + linux x64/arm64.
// The release is keyed by (windows 3-part version + 6-digit date code), both of
// which are present in the URLs - no fragile partial-download of the .deb.
//
// Emits to $GITHUB_OUTPUT: the four URLs, winver3/linuxver3/datecode, the release
// tag, and a `skip` flag (true when the release already has a .zip per arch slot).
//
// Env: FORCE=true to rebuild; GITHUB_REPOSITORY / GITHUB_TOKEN for the skip check.
// ---------------------------------------------------------------------------

import { appendFileSync } from "node:fs";

const PAGE = {
  windows: "https://im.qq.com/pcqq/index.shtml",
  linux:   "https://im.qq.com/linuxqq/index.shtml",
};
// Fallback config URLs if the page's rainbowConfigUrl can't be read.
const FALLBACK_CONFIG = {
  windows: "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/windowsConfig.js",
  linux:   "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js",
};

const FORCE = (process.env.FORCE || "").trim().toLowerCase() === "true";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(msg) {
  console.error(`::error::resolve: ${msg}`);
  process.exit(1);
}

async function fetchText(url, tries = 4) {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      // Best-effort cache-bust + revalidate. (cdn-go's COS edge mostly ignores
      // the query for its cache key, so this is not a reliable fix on its own —
      // the freshness floor check below is what actually guards against stale.)
      const u = url + (url.includes("?") ? "&" : "?") + "_cb=" + Date.now() + "." + i;
      const r = await fetch(u, {
        headers: {
          "User-Agent": "Mozilla/5.0 qq-lib-autogen",
          "Cache-Control": "no-cache, no-store, max-age=0",
          Pragma: "no-cache",
        },
        signal: AbortSignal.timeout(30000),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return await r.text();
    } catch (e) {
      last = e;
      await sleep(600 * (i + 1));
    }
  }
  throw new Error(`fetch failed for ${url}: ${last}`);
}

// Liveness check, straight against QQ's CDN (no third-party version list): HEAD
// the resolved download URL. A stale '/latest/' edge points at pruned files,
// which QQ returns 404 for. (Uses HEAD, not a Range GET — gtimg can reject Range
// from some CI IPs.)
async function urlLive(url) {
  if (!url) return true;
  try {
    const r = await fetch(url, {
      method: "HEAD",
      redirect: "follow",
      headers: { "User-Agent": "Mozilla/5.0 qq-lib-autogen" },
      signal: AbortSignal.timeout(30000),
    });
    // 403/404/410 => pruned/gone (dead). Anything else (2xx, 405, transient 5xx)
    // => treat as live and let the build job's actual download settle it.
    return ![403, 404, 410].includes(r.status);
  } catch {
    return true; // network hiccup: don't false-fail; the build job will retry
  }
}

// Rainbow config: `;(function(){var params= {...};  ...})()` -> pull the JSON.
function parseRainbow(js) {
  const m = js.match(/var\s+params\s*=\s*(\{[\s\S]*?\})\s*;/);
  if (!m) throw new Error("could not parse rainbow config JSON");
  return JSON.parse(m[1]);
}

// Parse the frontend: download page -> rainbowConfigUrl -> config params.
async function frontendConfig(which) {
  let cfgUrl = FALLBACK_CONFIG[which];
  try {
    const html = await fetchText(PAGE[which]);
    const m = html.match(/rainbowConfigUrl\s*=\s*["']([^"']+)["']/);
    if (m) {
      cfgUrl = m[1].startsWith("//") ? "https:" + m[1] : m[1];
      console.log(`::notice::resolve: ${which} frontend config -> ${cfgUrl}`);
    } else {
      console.log(`::notice::resolve: ${which} page had no rainbowConfigUrl; using fallback`);
    }
  } catch (e) {
    console.log(`::notice::resolve: ${which} page fetch failed (${e.message}); using fallback config`);
  }
  return parseRainbow(await fetchText(cfgUrl));
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
      signal: AbortSignal.timeout(30000),
    });
    if (!r.ok) return new Set();
    const rel = await r.json();
    return new Set((rel.assets || []).map((a) => a.name));
  } catch {
    return new Set();
  }
}

// --- resolve ---------------------------------------------------------------

const winCfg = await frontendConfig("windows");
const linCfg = await frontendConfig("linux");

const out = {
  winver3: winCfg.version || "",
  linuxver3: linCfg.version || "",
  update_date: winCfg.updateDate || linCfg.updateDate || "",
  win_x64_url: winCfg.ntDownloadX64Url || "",
  win_arm64_url: winCfg.ntDownloadARMUrl || "",
  linux_x64_url: linCfg.x64DownloadUrl?.deb || "",
  linux_arm64_url: linCfg.armDownloadUrl?.deb || "",
};
for (const [k, v] of Object.entries(out))
  if (!v && k.endsWith("_url")) console.error(`::warning::resolve: missing ${k} from frontend`);

if (!out.win_x64_url && !out.linux_x64_url)
  fail("frontend returned no download URLs (config shape changed or unreachable).");

// --- stale-config guard (QQ-only) ------------------------------------------
// cdn-go's "/latest/" rainbow config has been observed serving months-old
// content to some CI runners (e.g. 9.9.21 instead of 9.9.31), whose CDN files
// are pruned. Verify the resolved URLs are actually downloadable on QQ's CDN; if
// a stale config points at pruned (404) files, reject rather than build an
// ancient version that would 404 in the build jobs. A later run hits a fresh edge.
// (Cross-check: windows and linux of one release share a date code.)
const winDate = (out.win_x64_url.match(/_(\d{6})_/) || [])[1] || "";
const linDate = (out.linux_x64_url.match(/_(\d{6})_/) || [])[1] || "";
if (winDate && linDate && winDate !== linDate)
  console.error(`::warning::resolve: windows date ${winDate} != linux date ${linDate} — possible stale cache on one config.`);

const live = await Promise.all(
  [["win-x64", out.win_x64_url], ["win-arm64", out.win_arm64_url],
   ["linux-x64", out.linux_x64_url], ["linux-arm64", out.linux_arm64_url]]
    .map(async ([k, u]) => [k, u, await urlLive(u)]));
for (const [k, u, ok] of live) if (u) console.log(`::notice::resolve: ${ok ? "live" : "DEAD"} ${k} -> ${u}`);
const dead = live.filter(([, u, ok]) => u && !ok).map(([k]) => k);
if (dead.length)
  fail(
    `resolved download URL(s) not live on QQ's CDN: ${dead.join(", ")}. cdn-go's '/latest/' edge served ` +
    `this runner a stale config pointing at pruned files. Re-run — a later run usually hits a fresh edge.`
  );

// Date code (YYMMDD), and the per-build content hash from the .../release/<hash>/
// path segment. Tencent occasionally ships same-day rebuilds (same date, new
// hash), so the hash — not the date — is what makes a release key unique; we
// keep the date too for readability. The exact x.x.xx-xxxxx build goes into the
// asset names (detected from the binaries by the build jobs).
const anyUrl = out.win_x64_url || out.win_arm64_url || out.linux_x64_url || out.linux_arm64_url;
out.datecode = (anyUrl.match(/_(\d{6})_/) || [])[1] || "";
const hash = (anyUrl.match(/\/release\/([0-9a-f]{6,})\//) || [])[1] || "";

const keyparts = [out.winver3 || out.linuxver3, out.datecode, hash].filter(Boolean);
if (!keyparts.length) fail("could not derive a release key (no version/date/hash in frontend URLs).");
out.tag = `qq-${keyparts.join("-")}`;

// Skip when the release already has a .zip for each arch slot, regardless of the
// exact version/build in each filename (robust to cross-platform skew).
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

console.log("=== resolve (latest from frontend) ===");
for (const [k, v] of Object.entries(out)) console.log(`${k}: ${v}`);

import { sign, createHash, createPrivateKey } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";

// Re-publishing the same version copies an artifact onto itself, and a read-only source (e.g. a Nix store path)
// leaves a read-only copy a later publish cannot replace: skip same-path copies and keep published files 0644.
function publishCopy(src, dest) {
  if (resolve(src) === resolve(dest)) return;
  copyFileSync(src, dest);
  chmodSync(dest, 0o644);
}

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

function argList(name) {
  const flag = `--${name}`;
  const out = [];
  for (let i = 1; i + 1 < process.argv.length; i++) {
    if (process.argv[i] === flag && !process.argv[i + 1].startsWith("--")) {
      out.push(process.argv[i + 1]);
    }
  }
  return out;
}

const dllPath = resolve(arg("dll"));
const version = arg("version");
const target = arg("target", "client");
const targetChangelist = Number(arg("changelist", "647472"));
const channel = arg("channel", "stable");
const outputRoot = resolve(arg("output", "../ParadoxBackend/updates"));
const baseUrl = (arg("base-url", "https://paradox.mysticfox.dev")).replace(/\/$/, "");
const signingKeyPath = resolve(arg("key", ".secrets/mystic-runtime-update.private.pem"));
const extraPaths = argList("extra").map((p) => resolve(p));
const signingKey = createPrivateKey(readFileSync(signingKeyPath));
// Feed extras: the winmm proxy, plus any names a private P2P build lists in scripts/p2p/runtime-extra-names.json.
const p2pExtraNamesPath = new URL("./p2p/runtime-extra-names.json", import.meta.url);
const allowedExtraNames = new Set([
  "winmm.dll",
  ...(existsSync(p2pExtraNamesPath) ? JSON.parse(readFileSync(p2pExtraNamesPath, "utf8")) : []),
]);

if (!version || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error("--version must be a SemVer such as 0.4.13");
}
if (target !== "client" && target !== "server") throw new Error("--target must be client or server");
if (!Number.isSafeInteger(targetChangelist) || targetChangelist <= 0) throw new Error("Invalid --changelist");
const bytes = readFileSync(dllPath);
if (bytes.length === 0 || bytes.length > 200 * 1024 * 1024) throw new Error("DLL size is outside the safe range");

const sha256 = createHash("sha256").update(bytes).digest("hex");
const artifactName = `MysticParadox-${version}-${target}-${targetChangelist}.dll`;
const artifactDir = resolve(outputRoot, "runtime", target, channel, "windows-x86_64", version);
mkdirSync(artifactDir, { recursive: true });

// ── Load previous manifest ──
const latestPath = resolve(outputRoot, "runtime", target, channel, "windows-x86_64", "latest.json");
let prevManifest = null;
let prevArtifactDir = null;
if (existsSync(latestPath)) {
  try {
    prevManifest = JSON.parse(readFileSync(latestPath, "utf-8"));
    prevArtifactDir = resolve(outputRoot, "runtime", target, channel, "windows-x86_64", prevManifest.version);
  } catch { /* first publish */ }
}

// ── Main DLL: reuse signature if unchanged ──
let signatureBase64;
if (prevManifest && prevManifest.sha256 === sha256) {
  signatureBase64 = prevManifest.signature;
  // Copy the previous artifact so the versioned filename is present.
  const prevArtifactPath = resolve(prevArtifactDir, prevManifest.file);
  if (existsSync(prevArtifactPath)) {
    publishCopy(prevArtifactPath, resolve(artifactDir, artifactName));
  } else {
    publishCopy(dllPath, resolve(artifactDir, artifactName));
  }
  console.log(`  DLL unchanged (preserving signature from v${prevManifest.version})`);
} else {
  signatureBase64 = sign(null, bytes, signingKey).toString("base64");
  publishCopy(dllPath, resolve(artifactDir, artifactName));
}

const extraFiles = [];
const prevExtras = {};
if (prevManifest && prevManifest.extraFiles) {
  for (const e of prevManifest.extraFiles) {
    prevExtras[e.name] = e;
  }
}

for (const extraPath of extraPaths) {
  const extraName = basename(extraPath);
  if (!allowedExtraNames.has(extraName)) {
    throw new Error(`Extra file is not on the runtime allowlist: ${extraName || extraPath}`);
  }
  const extraBytes = readFileSync(extraPath);
  if (extraBytes.length === 0 || extraBytes.length > 200 * 1024 * 1024) throw new Error(`Extra file size is outside the safe range: ${extraPath}`);
  const extraSha256 = createHash("sha256").update(extraBytes).digest("hex");
  const prevExtra = prevExtras[extraName];

  if (prevExtra && prevExtra.sha256 === extraSha256) {
    // Unchanged — reuse the previous signature and file. Copy from the
    // previous artifact dir if available, otherwise from the local file.
    const prevSrc = resolve(prevArtifactDir, extraName);
    const src = existsSync(prevSrc) ? prevSrc : extraPath;
    publishCopy(src, resolve(artifactDir, extraName));
    extraFiles.push(prevExtra);
    console.log(`  extra: ${extraName} (unchanged, preserving signature from v${prevManifest.version})`);
  } else {
    const extraSig = sign(null, extraBytes, signingKey).toString("base64");
    publishCopy(extraPath, resolve(artifactDir, extraName));
    extraFiles.push({
      name: extraName,
      size: extraBytes.length,
      sha256: extraSha256,
      signature: extraSig,
      url: `${baseUrl}/launcher/v1/runtime/${encodeURIComponent(target)}/${encodeURIComponent(channel)}/windows-x86_64/extra/${encodeURIComponent(extraName)}`,
    });
    const tag = prevExtra ? "changed" : "new";
    console.log(`  extra: ${extraName} (${tag}, ${extraBytes.length} bytes, sha256: ${extraSha256})`);
  }
}

const manifest = {
  schema: 1,
  component: "ParadoxRuntime",
  target,
  version,
  channel,
  targetChangelist,
  platform: "windows-x86_64",
  size: bytes.length,
  sha256,
  signature: signatureBase64,
  file: artifactName,
  publishedAt: new Date().toISOString(),
  url: `${baseUrl}/launcher/v1/runtime/${encodeURIComponent(target)}/${encodeURIComponent(channel)}/windows-x86_64/download`,
  extraFiles,
};
writeFileSync(resolve(artifactDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
const latestDir = resolve(outputRoot, "runtime", target, channel, "windows-x86_64");
mkdirSync(latestDir, { recursive: true });
writeFileSync(resolve(latestDir, "latest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify({ target, version, sha256, artifact: resolve(artifactDir, artifactName), manifest: resolve(latestDir, "latest.json") }, null, 2));

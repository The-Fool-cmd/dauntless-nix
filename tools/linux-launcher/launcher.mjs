#!/usr/bin/env node
// dauntless-nix launcher: the minimal Linux client for a self-hosted Dauntless 1.14.7 server (DECISIONS D21).
// Part of dauntless-nix, a modified version of Mystic Paradox (AGPL-3.0-only; see NOTICE.md).
//
// It does only what play needs, mirroring ParadoxLauncher's protocol:
//   register/login  POST /launcher/v1/auth/{register,login,refresh}   (refresh token kept in a 0600 file)
//   sync            GET  /launcher/v1/runtime/stable/windows-x86_64   (signed manifest) + downloads; every file's
//                   SHA-256 and Ed25519 signature checked against the pinned runtimePublicKey, then installed beside
//                   the game exe in a hard-linked working copy of the pristine install
//   play            exe hash check, POST /launcher/v1/game-sessions -> exchangeCode, then the game under Proton with
//                   upstream's 13 arguments, MYSTICPARADOX_BACKEND_URL, MYSTICPARADOX_RUNTIME_PROFILE=production and
//                   WINEDLLOVERRIDES=winmm=n,b
//
// Config (JSON): $DAUNTLESS_NIX_CONFIG or $XDG_CONFIG_HOME/dauntless-nix/config.json
//   server            launcher API base, e.g. "https://10.77.0.1"
//   caCertFile        optional PEM to trust for `server` (pins a self-signed certificate)
//   gameBackendUrl    MYSTICPARADOX_BACKEND_URL for the game (default: server)
//   runtimePublicKey  base64 raw Ed25519 public key of the server's runtime feed
//   gameDir           pristine 1.14.7 install (holds Archon/ and Version.txt); never modified
//   instanceDir       working copy the game runs from (created from gameDir with hard links)
//   protonRun         path to dauntless-proton;  protonPrefix  its prefix directory
//   extraGameArgs     optional extra game arguments (e.g. ["-windowed"])

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import https from "node:https";
import http from "node:http";
import { spawn, spawnSync } from "node:child_process";
import readline from "node:readline";

const DEFAULT_EXE_SHA256 = "f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b";  // 1.14.7, CL 647472
let APPROVED_EXE_SHA256 = DEFAULT_EXE_SHA256;
const CHANGELIST = 647472;
const CHANNEL = "stable";
const EXE_REL = path.join("Archon", "Binaries", "Win64", "Dauntless-Win64-Shipping.exe");
const CORE_ARTIFACTS = ["MysticParadox.dll", "winmm.dll"];
const DEVICE = { deviceId: "dauntless-nix-linux-launcher", deviceName: `Linux (${os.hostname()})` };
const BRANDING_FLAGS = ["DISABLE_LOGIN_BRANDING.flag", "DISABLE_CREDITS_BRANDING.flag", "DISABLE_PRESS_START_BRANDING.flag"];

class Fail extends Error {}
const die = (message) => { throw new Fail(message); };

// ---------- config and state ----------
function configPath() {
  if (process.env.DAUNTLESS_NIX_CONFIG) return process.env.DAUNTLESS_NIX_CONFIG;
  const user = path.join(process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"), "dauntless-nix", "config.json");
  return fs.existsSync(user) ? user : "/etc/dauntless-nix/config.json";   // the NixOS client module writes the latter
}
const expand = (p) => (p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : p);
function loadConfig() {
  const file = configPath();
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { die(`cannot read config ${file}: ${e.message}`); }
  for (const key of ["server", "runtimePublicKey", "gameDir", "instanceDir", "protonRun", "protonPrefix"]) {
    if (typeof cfg[key] !== "string" || cfg[key] === "") die(`config ${file}: "${key}" is required`);
  }
  for (const key of ["gameDir", "instanceDir", "protonPrefix", "caCertFile"]) if (cfg[key]) cfg[key] = expand(cfg[key]);
  if (cfg.approvedExeSha256) APPROVED_EXE_SHA256 = String(cfg.approvedExeSha256).toLowerCase();   // tests only
  cfg.server = cfg.server.replace(/\/+$/, "");
  cfg.gameBackendUrl = (cfg.gameBackendUrl ?? cfg.server).replace(/\/+$/, "");
  if (!/^https?:\/\/[^/?#@\s]+$/.test(cfg.gameBackendUrl)) die("gameBackendUrl must be scheme://host[:port] only");
  cfg.ca = cfg.caCertFile ? fs.readFileSync(cfg.caCertFile) : undefined;
  return cfg;
}
const stateDir = () => path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "dauntless-nix");
const sessionFile = () => path.join(stateDir(), "session.json");
function saveSession(s) {
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  const tmp = sessionFile() + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(s), { mode: 0o600 });
  fs.renameSync(tmp, sessionFile());
}
function loadSession() {
  try { return JSON.parse(fs.readFileSync(sessionFile(), "utf8")); } catch { return undefined; }
}

// ---------- HTTP ----------
function request(cfg, method, urlString, { json, token, raw = false } = {}) {
  const url = new URL(urlString);
  const mod = url.protocol === "https:" ? https : http;
  const body = json === undefined ? undefined : Buffer.from(JSON.stringify(json));
  const headers = { "accept": "application/json", "user-agent": "dauntless-nix-launcher" };
  if (body) { headers["content-type"] = "application/json"; headers["content-length"] = body.length; }
  if (token) headers.authorization = `Bearer ${token}`;
  return new Promise((resolve, reject) => {
    const req = mod.request(url, { method, headers, ca: cfg.ca, timeout: 30000 }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && raw) {
          return resolve(request(cfg, method, new URL(res.headers.location, url).toString(), { raw }));
        }
        if (raw) return res.statusCode === 200 ? resolve(buf) : reject(new Fail(`${method} ${url.pathname}: HTTP ${res.statusCode}`));
        let data;
        try { data = buf.length ? JSON.parse(buf.toString("utf8")) : {}; } catch { data = { raw: buf.toString("utf8").slice(0, 200) }; }
        if (res.statusCode >= 200 && res.statusCode < 300) return resolve(data);
        const err = data?.error ?? {};
        reject(new Fail(`${method} ${url.pathname}: HTTP ${res.statusCode} ${err.code ?? ""} ${err.message ?? data.raw ?? ""}`.trim()));
      });
    });
    req.on("timeout", () => req.destroy(new Fail(`${method} ${url.pathname}: timed out`)));
    req.on("error", (e) => reject(e instanceof Fail ? e : new Fail(`${method} ${url.host}: ${e.message}`)));
    if (body) req.write(body);
    req.end();
  });
}
const api = (cfg, method, p, opts) => request(cfg, method, cfg.server + p, opts);

// ---------- prompts ----------
async function prompt(question, { hidden = false } = {}) {
  if (hidden && process.env.DAUNTLESS_NIX_PASSWORD) return process.env.DAUNTLESS_NIX_PASSWORD;
  if (!process.stdin.isTTY) {
    const rl = readline.createInterface({ input: process.stdin });
    for await (const line of rl) { rl.close(); return line; }
    die("no input");
  }
  return await new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (hidden) rl._writeToOutput = (s) => { if (s.includes(question)) rl.output.write(s); };
    rl.question(question, (answer) => { rl.close(); if (hidden) process.stdout.write("\n"); resolve(answer); });
  });
}

// ---------- auth ----------
async function refreshed(cfg) {
  const s = loadSession();
  if (!s?.refreshToken) die("not signed in: run `dauntless-nix-launcher login`");
  const r = await api(cfg, "POST", "/launcher/v1/auth/refresh", { json: { refreshToken: s.refreshToken, ...DEVICE } });
  saveSession({ refreshToken: r.refreshToken, account: r.account });
  return r;
}

// ---------- files ----------
const sha256File = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
const sha256 = (b) => crypto.createHash("sha256").update(b).digest("hex");
function ed25519Key(rawB64) {
  const raw = Buffer.from(rawB64, "base64");
  if (raw.length !== 32) die("runtimePublicKey must be a base64 raw 32-byte Ed25519 key");
  return crypto.createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]), format: "der", type: "spki" });
}
function verifyArtifact(name, bytes, entry, key) {
  if (bytes.length !== Number(entry.size ?? bytes.length)) die(`${name}: size mismatch`);
  if (sha256(bytes) !== String(entry.sha256).toLowerCase()) die(`${name}: SHA-256 does not match the manifest`);
  if (!crypto.verify(null, bytes, key, Buffer.from(String(entry.signature ?? ""), "base64"))) {
    die(`${name}: Ed25519 signature does not verify against the pinned runtime key`);
  }
}
function win64(cfg) { return path.join(cfg.instanceDir, "Archon", "Binaries", "Win64"); }
function checkPristine(cfg) {
  const exe = path.join(cfg.gameDir, EXE_REL);
  if (!fs.existsSync(exe)) die(`game not found: ${exe}`);
  const have = sha256File(exe);
  if (have !== APPROVED_EXE_SHA256) die(`${exe} is not Dauntless 1.14.7 (SHA-256 ${have}); repair the install`);
}
// A half-made copy of a read-only install has read-only directories: make them writable before removing.
function forceRemove(dir) {
  if (!fs.existsSync(dir)) return;
  spawnSync("chmod", ["-R", "u+w", dir], { stdio: "ignore" });
  fs.rmSync(dir, { recursive: true, force: true });
}
function ensureInstance(cfg) {
  if (fs.existsSync(path.join(cfg.instanceDir, EXE_REL))) return;
  checkPristine(cfg);
  const tmp = cfg.instanceDir + ".tmp";
  forceRemove(tmp);
  fs.mkdirSync(path.dirname(cfg.instanceDir), { recursive: true });
  let r = spawnSync("cp", ["-al", cfg.gameDir, tmp], { stdio: "inherit" });
  if (r.status !== 0) {
    console.error("hard links not possible (different filesystem?): making a full copy (~16 GB)");
    forceRemove(tmp);
    r = spawnSync("cp", ["-a", cfg.gameDir, tmp], { stdio: "inherit" });
    if (r.status !== 0) die("could not create the game working copy");
  }
  fs.renameSync(tmp, cfg.instanceDir);
}

// ---------- commands ----------
async function cmdRegister(cfg, args) {
  const email = args.email ?? await prompt("Email: ");
  const name = args.name ?? await prompt("Display name: ");
  const password = await prompt("Password: ", { hidden: true });
  const r = await api(cfg, "POST", "/launcher/v1/auth/register", { json: { displayName: name, email, password, ...DEVICE } });
  if (r.refreshToken) { saveSession({ refreshToken: r.refreshToken, account: r.account }); console.log(`registered and signed in as ${r.account?.displayName}`); }
  else console.log(`registered${r.verificationRequired ? " (verify the email, then log in)" : "; now run: dauntless-nix-launcher login"}`);
}
async function cmdLogin(cfg, args) {
  const email = args.email ?? await prompt("Email: ");
  const password = await prompt("Password: ", { hidden: true });
  const r = await api(cfg, "POST", "/launcher/v1/auth/login", { json: { email, password, ...DEVICE } });
  saveSession({ refreshToken: r.refreshToken, account: r.account });
  console.log(`signed in as ${r.account.displayName} (${r.account.userId})`);
}
async function cmdLogout(cfg) {
  const s = loadSession();
  if (s?.refreshToken) await api(cfg, "POST", "/launcher/v1/auth/logout", { json: { refreshToken: s.refreshToken } }).catch(() => {});
  fs.rmSync(sessionFile(), { force: true });
  console.log("signed out");
}
async function cmdStatus(cfg) {
  const st = await api(cfg, "GET", "/launcher/v1/status");
  console.log(`server ${cfg.server}: online=${st.online} build=${st.supportedBuildChangelist}`);
  const s = loadSession();
  console.log(s?.account ? `signed in as ${s.account.displayName}` : "not signed in");
}
async function cmdSync(cfg) {
  ensureInstance(cfg);
  const manifest = await api(cfg, "GET", `/launcher/v1/runtime/${CHANNEL}/windows-x86_64`);
  if (Number(manifest.targetChangelist) !== CHANGELIST || manifest.platform !== "windows-x86_64") die("runtime manifest targets another build");
  const key = ed25519Key(cfg.runtimePublicKey);
  const files = [{ name: "MysticParadox.dll", entry: manifest, url: manifest.url }];
  for (const e of manifest.extraFiles ?? []) files.push({ name: e.name, entry: e, url: e.url });
  for (const n of CORE_ARTIFACTS) if (!files.some((f) => f.name === n)) die(`runtime manifest lacks ${n}`);
  const dir = win64(cfg);
  fs.chmodSync(dir, 0o755);
  for (const f of files) {
    if (!CORE_ARTIFACTS.includes(f.name)) continue;   // optional co-op files are not used by this launcher
    const dest = path.join(dir, f.name);
    if (fs.existsSync(dest) && sha256File(dest) === String(f.entry.sha256).toLowerCase()) continue;
    // Download from our own server whatever host the manifest names (no third-party fetches).
    const u = new URL(f.url);
    const bytes = await request(cfg, "GET", cfg.server + u.pathname, { raw: true });
    verifyArtifact(f.name, bytes, f.entry, key);
    fs.rmSync(dest, { force: true });           // never write through a hard link into the pristine install
    fs.writeFileSync(dest + ".tmp", bytes, { mode: 0o644 });
    fs.renameSync(dest + ".tmp", dest);
    console.log(`installed ${f.name} ${manifest.version}`);
  }
  for (const flag of BRANDING_FLAGS) fs.writeFileSync(path.join(dir, flag), "");
  fs.rmSync(path.join(dir, "mystic_loader.ini"), { force: true });
  console.log(`runtime ${manifest.version} ready`);
  return manifest.version;
}
async function cmdPlay(cfg, args) {
  const version = await cmdSync(cfg);
  const exe = path.join(cfg.instanceDir, EXE_REL);
  const exeSha = sha256File(exe);
  if (exeSha !== APPROVED_EXE_SHA256) die(`${exe} is not the approved 1.14.7 executable`);
  const artifacts = CORE_ARTIFACTS.map((name) => ({ name, sha256: sha256File(path.join(win64(cfg), name)) }));
  const status = await api(cfg, "GET", "/launcher/v1/status");
  if (!status.online) die("the server reports offline");
  const session = await refreshed(cfg);
  const ticket = await api(cfg, "POST", "/launcher/v1/game-sessions", {
    token: session.accessToken,
    json: { buildChangelist: CHANGELIST, executableSha256: exeSha, runtimeChannel: CHANNEL,
            runtimeManifestVersion: version, runtimeArtifacts: artifacts },
  });
  const { userId, displayName } = session.account;
  const gameArgs = [
    "-DisableEOS", "-EpicPortal", "-NoEAC", "-AUTH_TYPE=exchangecode",
    `-AUTH_LOGIN=${userId}`, `-AUTH_PASSWORD=${ticket.exchangeCode}`,
    "-epicapp=Archon", "-epicenv=Prod", `-epicusername=${displayName}`, `-epicuserid=${userId}`,
    `-epicaccountid=${userId}`, "-epicsandboxid=jackal", "-epicdeploymentid=53565ba467df4edbb6f5a3d939a8b4f2",
    ...(cfg.extraGameArgs ?? []),
  ];
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (/^MYSTICPARADOX_/i.test(k)) delete env[k];  // no stray runtime switches
  Object.assign(env, {
    MYSTICPARADOX_BACKEND_URL: cfg.gameBackendUrl,
    MYSTICPARADOX_RUNTIME_PROFILE: "production",
    WINEDLLOVERRIDES: "winmm=n,b",
  });
  if (args["dry-run"]) {
    console.log(JSON.stringify({ protonRun: cfg.protonRun, prefix: cfg.protonPrefix, exe,
      args: gameArgs.map((a) => a.startsWith("-AUTH_PASSWORD=") ? "-AUTH_PASSWORD=<exchange code>" : a),
      backendUrl: env.MYSTICPARADOX_BACKEND_URL, exchangeCodeIssued: Boolean(ticket.exchangeCode) }));
    return;
  }
  console.log(`starting Dauntless as ${displayName}`);
  const child = spawn(cfg.protonRun, [cfg.protonPrefix, exe, ...gameArgs], { cwd: win64(cfg), env, stdio: "inherit" });
  await new Promise((resolve) => child.on("exit", (code) => { process.exitCode = code ?? 1; resolve(); }));
}

// ---------- main ----------
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) { const k = a.slice(2); out[k] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true; }
    else out._.push(a);
  }
  return out;
}
const USAGE = `usage: dauntless-nix-launcher <command>
  register [--email E] [--name N]   create an account on the server (password asked, or DAUNTLESS_NIX_PASSWORD)
  login [--email E]                 sign in
  logout                            sign out and forget the session
  status                            server and account status
  sync                              fetch and verify the signed runtime, prepare the game copy
  play [--dry-run]                  sync, request a session and start Dauntless under Proton`;
const COMMANDS = { register: cmdRegister, login: cmdLogin, logout: cmdLogout, status: cmdStatus, sync: cmdSync, play: cmdPlay };
const args = parseArgs(process.argv.slice(2));
const command = COMMANDS[args._[0]];
if (!command) { console.error(USAGE); process.exit(64); }
try {
  await command(loadConfig(), args);
} catch (e) {
  if (e instanceof Fail) { console.error(`dauntless-nix-launcher: ${e.message}`); process.exit(1); }
  throw e;
}

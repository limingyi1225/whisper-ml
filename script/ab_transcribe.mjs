#!/usr/bin/env node
// A/B harness for the Realtime transcription side.
//
// Every claim in README's "实测" paragraphs came from measurements like these, and the
// model swap invalidated all of them: the delta counts, the 737/811/1250/1937ms
// time-to-first-word ladder, and the finding that `prompt` degrades accuracy were all
// taken on gpt-realtime-whisper and gpt-4o-transcribe. This script exists so those
// numbers can be retaken against whatever the app is actually pointed at, and so the
// keywords/languages questions get decided by data rather than by the docs' adjectives.
//
// It talks to OpenAI directly, never through the relay: the relay's allowlist is
// derived from the Swift enum, so a model that has been swapped out is no longer
// reachable that way — and comparing the new model against the old one is the entire
// point. That also keeps the relay's rate limits out of the measurement.
//
// What it deliberately copies from the app, because a benchmark that does not is
// measuring something else:
//
//   - the session config from `RealtimeClient.sendSessionUpdate`, field for field;
//   - 24 kHz mono PCM16, the format `AudioCapture` converts to;
//   - ~2048-byte appends, which is what one 2048-frame tap at a 48 kHz input becomes
//     after conversion;
//   - **wall-clock pacing**. Audio goes out at the speed it would be spoken. Dumping
//     the file in one burst would hand the model the whole utterance up front and turn
//     time-to-first-word into a measure of nothing;
//   - the clock starting only after `session.updated`. The app keeps its socket warm
//     and open long before the key is pressed, so connection setup is not part of the
//     latency the user feels, and must not be part of the number here either.
//
// Arms are interleaved per file rather than run in blocks — the same reason the polish
// A/B was interleaved. Network conditions drift over a run, and a block layout hands
// the whole drift to whichever arm was unlucky.
//
// Usage:
//   script/ab_transcribe.mjs --audio DIR [--arms live,live-kw] [--repeat 2]
//   script/ab_transcribe.mjs --list          # what it found, and what it would cost
//
// Accuracy is not scored here, on purpose. There is no reference text, and inventing
// one from another model's output would just measure agreement with that model. The
// report puts the arms' transcripts side by side and flags where they disagree, which
// is the only place a human has to look.

import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";

const ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));

// `ws` lives in the relay's dependency tree; resolving from there keeps this script
// from needing an install of its own. Node's global WebSocket cannot be used: the
// WHATWG API has no way to set an Authorization header.
let WebSocketImpl;
try {
  WebSocketImpl = createRequire(join(ROOT, "server", "package.json"))("ws");
} catch {
  fail("cannot load `ws` — run `npm install` in server/ first");
}

const BYTES_PER_SECOND = 48_000; // 24 kHz × 1 channel × 2 bytes, same as AudioCapture
const CHUNK_BYTES = 2048;
const REALTIME_URL = "wss://api.openai.com/v1/realtime?intent=transcription";
const SESSION_TIMEOUT_MS = 20_000;
const TAIL_TIMEOUT_MS = 60_000;

// Per-minute list prices, for the cost estimate only. Wrong numbers here cost nothing
// but a misleading estimate.
const PRICE_PER_MINUTE = {
  "gpt-live-transcribe": 0.017,
  "gpt-realtime-whisper": 0.017,
  "gpt-transcribe": 0.0045,
  "gpt-4o-transcribe": 0.006,
  "gpt-4o-mini-transcribe": 0.003,
};

// The arms. `keywords: true` means "substitute the vocabulary list resolved below", so
// that one list is shared and the arm table stays readable.
//
// Only `live` vs `old` answers "did the swap help". The rest are one-variable-at-a-time
// probes off `live`; changing two fields in one arm makes its result unattributable.
const ARMS = {
  live: { model: "gpt-live-transcribe", delay: "low" },
  "live-kw": { model: "gpt-live-transcribe", delay: "low", keywords: true },
  "live-lang": { model: "gpt-live-transcribe", delay: "low", languages: ["zh", "en"] },
  "live-minimal": { model: "gpt-live-transcribe", delay: "minimal" },
  old: { model: "gpt-realtime-whisper", delay: "low" },
  batch: { model: "gpt-transcribe" },
  "batch-kw": { model: "gpt-transcribe", keywords: true },
};

const DEFAULT_ARMS = ["live", "old"];

function fail(message) {
  console.error(`!! ${message}`);
  process.exit(1);
}

// MARK: - Arguments

function parseArgs(argv) {
  const options = {
    audio: join(ROOT, "script", "ab-audio"),
    out: join(ROOT, "script", "ab-out"),
    arms: DEFAULT_ARMS,
    repeat: 1,
    list: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => {
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) fail(`${flag} needs a value`);
      i += 1;
      return next;
    };
    switch (flag) {
      case "--audio": options.audio = resolve(value()); break;
      case "--out": options.out = resolve(value()); break;
      case "--arms": options.arms = value().split(",").map((a) => a.trim()).filter(Boolean); break;
      case "--repeat": options.repeat = Number(value()); break;
      case "--list": options.list = true; break;
      case "--help": case "-h": usage(); process.exit(0); break;
      default: fail(`unknown flag ${flag}`);
    }
  }
  if (!Number.isInteger(options.repeat) || options.repeat < 1) {
    fail("--repeat must be a positive integer");
  }
  for (const arm of options.arms) {
    if (!ARMS[arm]) fail(`unknown arm "${arm}" — known: ${Object.keys(ARMS).join(", ")}`);
  }
  return options;
}

function usage() {
  console.log(`
Usage: script/ab_transcribe.mjs [options]

  --audio DIR    audio to run (default script/ab-audio)
  --out DIR      where results land (default script/ab-out)
  --arms a,b     which arms, comma separated (default ${DEFAULT_ARMS.join(",")})
  --repeat N     passes over the whole set, interleaved (default 1)
  --list         show what was found and what it would cost, run nothing

Arms:
${Object.entries(ARMS).map(([id, arm]) => `  ${id.padEnd(13)} ${describeArm(arm)}`).join("\n")}

The API key is read from the same keychain item the app uses:
  security find-generic-password -s com.mingyili.Whisper -a openai-api-key -w
`);
}

function describeArm(arm) {
  const parts = [arm.model];
  if (arm.delay) parts.push(`delay=${arm.delay}`);
  if (arm.keywords) parts.push("keywords");
  if (arm.languages) parts.push(`languages=${arm.languages.join("+")}`);
  return parts.join(" · ");
}

// MARK: - Inputs

function loadAPIKey() {
  if (process.env.OPENAI_API_KEY) return process.env.OPENAI_API_KEY.trim();
  try {
    return execFileSync("security", [
      "find-generic-password", "-s", "com.mingyili.Whisper", "-a", "openai-api-key", "-w",
    ], { encoding: "utf8" }).trim();
  } catch {
    fail("no API key: set OPENAI_API_KEY, or store one in the app's keychain item");
  }
}

// The list the app would actually send, so a keywords arm tests the real thing rather
// than a sample of it. Falls back to the built-ins that `AppSettings` always contributes.
const BUILT_IN_VOCABULARY = ["李铭一"];

function loadVocabulary(audioDir) {
  const override = join(audioDir, "keywords.txt");
  const raw = existsSync(override)
    ? readFileSync(override, "utf8")
    : readDefaultsVocabulary();
  const terms = [];
  const seen = new Set();
  for (const line of (raw ?? "").split(/\r?\n/)) {
    const term = line.trim();
    // Same caps as AppSettings.parseVocabulary — a harness that accepts terms the app
    // would drop is testing a list the app can never send.
    if (!term || term.length > 40 || seen.has(term)) continue;
    seen.add(term);
    terms.push(term);
    if (terms.length === 100) break;
  }
  return [...BUILT_IN_VOCABULARY, ...terms.filter((t) => !BUILT_IN_VOCABULARY.includes(t))];
}

function readDefaultsVocabulary() {
  try {
    return execFileSync("defaults", ["read", "com.mingyili.Whisper", "vocabulary"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null; // never set, which is not an error
  }
}

const AUDIO_EXTENSIONS = new Set([".wav", ".m4a", ".mp3", ".caf", ".aiff", ".aif", ".flac", ".mp4"]);

function findAudio(dir) {
  if (!existsSync(dir)) {
    fail(`no audio directory at ${dir}\n   record a few utterances into it first — see --help`);
  }
  const files = readdirSync(dir)
    .filter((name) => AUDIO_EXTENSIONS.has(extname(name).toLowerCase()))
    .sort()
    .map((name) => join(dir, name));
  if (files.length === 0) fail(`no audio files in ${dir}`);
  return files;
}

/// Converts anything afconvert understands into the exact bytes the app would send.
/// Cached: conversion is deterministic, and a repeat run should spend its time on the
/// API rather than on transcoding.
function toPCM(file, cacheDir) {
  const cached = join(cacheDir, `${basename(file, extname(file))}.pcm`);
  if (existsSync(cached)) return readFileSync(cached);

  const wav = join(cacheDir, `${basename(file, extname(file))}.24k.wav`);
  try {
    execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", file, wav], {
      stdio: ["ignore", "ignore", "pipe"],
    });
  } catch (error) {
    fail(`afconvert could not read ${basename(file)}: ${error.stderr?.toString().trim() ?? error.message}`);
  }
  const pcm = pcmFromWav(readFileSync(wav));
  writeFileSync(cached, pcm);
  return pcm;
}

/// Pulls the `data` chunk out of a RIFF/WAVE file. afconvert writes a `fmt ` chunk and
/// sometimes more before the samples, so seeking a fixed offset is not safe.
function pcmFromWav(buffer) {
  if (buffer.toString("ascii", 0, 4) !== "RIFF" || buffer.toString("ascii", 8, 12) !== "WAVE") {
    fail("afconvert produced something that is not a WAVE file");
  }
  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "data") return buffer.subarray(body, Math.min(body + size, buffer.length));
    offset = body + size + (size % 2); // RIFF chunks are word-aligned
  }
  fail("no data chunk in the converted WAVE file");
}

// MARK: - One run

/// Streams one file through one arm and returns what it cost and what came back.
///
/// Resolves rather than throws on a server-side rejection: one arm failing on one file
/// (an unsupported field, a transient 5xx) should leave the rest of the matrix intact
/// and show up in the report as a gap.
async function runOnce({ apiKey, arm, armID, pcm, label, vocabulary }) {
  const transcription = { model: arm.model };
  if (arm.delay) transcription.delay = arm.delay;
  if (arm.keywords) transcription.keywords = vocabulary;
  if (arm.languages) transcription.languages = arm.languages;

  const socket = new WebSocketImpl(REALTIME_URL, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });

  const result = {
    arm: armID, file: label, model: arm.model,
    audioSeconds: pcm.length / BYTES_PER_SECOND,
    // `preCommitDeltas` is the one that decides live typing, and it is not the same
    // question as "does this model stream". Measured: gpt-transcribe emits just as many
    // deltas as gpt-live-transcribe over an identical clip — it simply emits every one
    // of them *after* the commit, so there is nothing to type while the user is still
    // speaking. A plain delta count would call those two models identical.
    ttfwMs: null, deltas: 0, preCommitDeltas: 0, tailMs: null, transcript: null, error: null,
  };

  let settle;
  const done = new Promise((r) => { settle = r; });
  let timer = null;
  const disarm = () => { if (timer) clearTimeout(timer); };
  const armTimeout = (ms, why) => {
    disarm();
    timer = setTimeout(() => { result.error ??= why; socket.close(); settle(); }, ms);
  };

  let audioStart = null;
  let commitAt = null;
  let ready = null;

  socket.on("open", () => {
    socket.send(JSON.stringify({
      type: "session.update",
      event_id: "ab-session-1",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription,
            turn_detection: null,
          },
        },
      },
    }));
  });

  socket.on("message", (data) => {
    let event;
    try { event = JSON.parse(data.toString("utf8")); } catch { return; }
    switch (event.type) {
      case "session.updated":
        ready?.();
        break;
      case "conversation.item.input_audio_transcription.delta":
        if (event.delta) {
          result.deltas += 1;
          if (commitAt === null) result.preCommitDeltas += 1;
          // From audio start, not from the commit: this is the number the user feels,
          // and the only one comparable to the ladder in the settings pane.
          result.ttfwMs ??= Math.round(performance.now() - audioStart);
        }
        break;
      case "conversation.item.input_audio_transcription.completed":
        result.transcript = event.transcript ?? "";
        result.tailMs = commitAt === null ? null : Math.round(performance.now() - commitAt);
        disarm();
        socket.close();
        settle();
        break;
      case "conversation.item.input_audio_transcription.failed":
        result.error = event.error?.message ?? "transcription failed";
        disarm(); socket.close(); settle();
        break;
      case "error":
        // Field rejections name the offending param; without it an unsupported
        // `keywords` is indistinguishable from a dead session.
        result.error = [event.error?.message, event.error?.param && `(${event.error.param})`]
          .filter(Boolean).join(" ");
        disarm(); socket.close(); settle();
        break;
    }
  });

  socket.on("error", (error) => {
    result.error ??= error.message;
    disarm(); settle();
  });
  socket.on("close", () => { disarm(); settle(); });

  // The app's socket is warm and configured long before the key goes down, so setup
  // is excluded here too — the clock starts below, after the session is live.
  armTimeout(SESSION_TIMEOUT_MS, "session did not come up");
  const sessionReady = new Promise((r) => { ready = r; });
  const outcome = await Promise.race([sessionReady, done.then(() => "dead")]);
  if (outcome === "dead" || result.error) return result;

  audioStart = performance.now();
  armTimeout(TAIL_TIMEOUT_MS, "no response while streaming");
  for (let offset = 0; offset < pcm.length; offset += CHUNK_BYTES) {
    if (socket.readyState !== WebSocketImpl.OPEN) break;
    // Deadline-based, not sleep(chunkDuration): accumulating the scheduler's overshoot
    // would stretch a 30 s utterance well past 30 s and inflate every latency below it.
    const due = audioStart + (offset / BYTES_PER_SECOND) * 1000;
    const wait = due - performance.now();
    if (wait > 1) await sleep(wait);
    socket.send(JSON.stringify({
      type: "input_audio_buffer.append",
      event_id: `ab-turn-1-${offset}`,
      audio: pcm.subarray(offset, offset + CHUNK_BYTES).toString("base64"),
    }));
  }
  if (result.error) return result;

  if (socket.readyState === WebSocketImpl.OPEN) {
    commitAt = performance.now();
    socket.send(JSON.stringify({ type: "input_audio_buffer.commit", event_id: "ab-turn-1-commit" }));
    armTimeout(TAIL_TIMEOUT_MS, "no transcript after the commit");
  }
  await done;
  return result;
}

// MARK: - Report

/// Punctuation and spacing differ constantly between models and are not what anybody is
/// adjudicating, so disagreement is judged on the characters that carry the words.
function normalize(text) {
  return (text ?? "")
    .toLowerCase()
    .replace(/[\s\p{P}\p{S}]/gu, "");
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

function buildReport(results, armIDs, vocabulary, options) {
  const lines = [];
  lines.push("# 转写模型 A/B", "");
  lines.push(`音频 ${new Set(results.map((r) => r.file)).size} 条 · 每条每臂跑 ${options.repeat} 次 · 共 ${results.length} 次调用`, "");

  lines.push("## 配置", "");
  lines.push("| 臂 | 配置 |", "| --- | --- |");
  for (const id of armIDs) lines.push(`| \`${id}\` | ${describeArm(ARMS[id])} |`);
  lines.push("");
  if (armIDs.some((id) => ARMS[id].keywords)) {
    lines.push(`keywords 用的是这 ${vocabulary.length} 条：${vocabulary.join("、")}`, "");
  }

  lines.push("## 延迟", "");
  lines.push(
    "首字延迟从音频开始算起，和设置里那把尺子同一个口径。松手→出字是 commit 到 completed。",
    "",
    "**「commit 前 delta」是判断能不能边说边出字的唯一指标**，delta 总数不是——非流式模型",
    "照样会发一大把 delta，只不过全在 commit 之后，那时候人已经松手了。总数这一列只用来",
    "确认两边确实在同一条流上，不要拿它比较。",
    "");
  lines.push("| 臂 | 首字中位数 | 首字 p90 | commit 前 delta | delta 总数 | 松手→出字中位数 | 失败 |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- |");
  for (const id of armIDs) {
    const rows = results.filter((r) => r.arm === id);
    const ok = rows.filter((r) => !r.error);
    const ttfw = ok.map((r) => r.ttfwMs).filter((v) => v !== null);
    const tail = ok.map((r) => r.tailMs).filter((v) => v !== null);
    const live = ok.map((r) => r.preCommitDeltas);
    const deltas = ok.map((r) => r.deltas);
    lines.push([
      `| \`${id}\``,
      ttfw.length ? `${median(ttfw)} ms` : "—",
      ttfw.length ? `${percentile(ttfw, 90)} ms` : "—",
      live.length ? `${median(live)}` : "—",
      deltas.length ? `${median(deltas)}` : "—",
      tail.length ? `${median(tail)} ms` : "—",
      `${rows.length - ok.length}/${rows.length} |`,
    ].join(" | "));
  }
  lines.push("");

  const failures = results.filter((r) => r.error);
  if (failures.length) {
    lines.push("## 失败", "");
    for (const f of failures) lines.push(`- \`${f.arm}\` / ${f.file}：${f.error}`);
    lines.push("");
  }

  lines.push("## 逐句对照", "");
  lines.push("只有标了 **⚠️ 不一致** 的需要你看——其余各臂结果在忽略标点后完全相同。", "");
  const files = [...new Set(results.map((r) => r.file))];
  let disagreements = 0;
  for (const file of files) {
    const perArm = armIDs.map((id) => {
      const rows = results.filter((r) => r.arm === id && r.file === file && !r.error);
      return { id, transcripts: [...new Set(rows.map((r) => r.transcript))] };
    });
    const variants = new Set(perArm.flatMap((a) => a.transcripts.map(normalize)).filter(Boolean));
    const disagrees = variants.size > 1;
    if (disagrees) disagreements += 1;
    lines.push(`### ${file}${disagrees ? "  ⚠️ 不一致" : ""}`, "");
    for (const { id, transcripts } of perArm) {
      if (transcripts.length === 0) { lines.push(`- \`${id}\`：（失败）`); continue; }
      // Repeats of one arm disagreeing with itself is its own finding — non-determinism
      // that big would make any single-run comparison between arms meaningless.
      for (const t of transcripts) lines.push(`- \`${id}\`${transcripts.length > 1 ? " ↺" : ""}：${t}`);
    }
    lines.push("");
  }
  lines.splice(lines.indexOf("## 逐句对照") + 2, 0,
    `${files.length} 条里有 ${disagreements} 条各臂对不上。`, "");

  return lines.join("\n");
}

// MARK: - Main

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const files = findAudio(options.audio);
  const vocabulary = loadVocabulary(options.audio);

  mkdirSync(options.out, { recursive: true });
  const cacheDir = join(options.out, "pcm");
  mkdirSync(cacheDir, { recursive: true });

  const clips = files.map((file) => {
    const pcm = toPCM(file, cacheDir);
    return { label: basename(file), pcm, seconds: pcm.length / BYTES_PER_SECOND };
  });

  const totalSeconds = clips.reduce((sum, c) => sum + c.seconds, 0) * options.repeat;
  const cost = options.arms.reduce(
    (sum, id) => sum + (PRICE_PER_MINUTE[ARMS[id].model] ?? 0) * (totalSeconds / 60), 0);

  console.log(`音频     ${clips.length} 条，共 ${totalSeconds.toFixed(1)}s（含 ${options.repeat} 轮重复）`);
  for (const c of clips) console.log(`         ${c.label} — ${c.seconds.toFixed(1)}s`);
  console.log(`臂       ${options.arms.join(", ")}`);
  console.log(`keywords ${vocabulary.length} 条：${vocabulary.slice(0, 8).join("、")}${vocabulary.length > 8 ? " …" : ""}`);
  console.log(`调用     ${clips.length * options.arms.length * options.repeat} 次`);
  console.log(`估价     $${cost.toFixed(3)}`);
  if (options.list) return;
  console.log("");

  const apiKey = loadAPIKey();
  const results = [];
  let n = 0;
  const total = clips.length * options.arms.length * options.repeat;
  for (let pass = 0; pass < options.repeat; pass += 1) {
    for (const clip of clips) {
      // Interleaved here: all arms for one clip, back to back, before moving on.
      for (const armID of options.arms) {
        n += 1;
        process.stdout.write(`[${String(n).padStart(String(total).length)}/${total}] ${armID} · ${clip.label} … `);
        const result = await runOnce({
          apiKey, arm: ARMS[armID], armID, pcm: clip.pcm, label: clip.label, vocabulary,
        });
        results.push(result);
        console.log(result.error
          ? `失败：${result.error}`
          : `首字 ${result.ttfwMs ?? "—"}ms · commit 前 ${result.preCommitDeltas}/${result.deltas} deltas · 尾 ${result.tailMs ?? "—"}ms`);
      }
    }
  }

  const jsonPath = join(options.out, "results.json");
  const reportPath = join(options.out, "report.md");
  writeFileSync(jsonPath, `${JSON.stringify(results, null, 2)}\n`);
  writeFileSync(reportPath, `${buildReport(results, options.arms, vocabulary, options)}\n`);
  console.log(`\n${reportPath}\n${jsonPath}`);
}

await main();

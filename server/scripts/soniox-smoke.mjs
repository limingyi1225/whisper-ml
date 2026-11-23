#!/usr/bin/env node
// Checks the Soniox bridge's assumptions against the real service.
//
// `src/soniox-realtime.js` was written from Soniox's published reference, so every
// behaviour it leans on started as a documented one rather than an observed one. This
// script talks to Soniox directly — no relay, no app — and does exactly what the bridge
// does, in the same order, so each assumption gets a reading instead of a citation. The
// readings from its one run so far are recorded at the top of the bridge; run it again
// whenever Soniox changes the model or the bridge changes what it sends.
//
// Because it bypasses the relay, it says nothing about what the relay forwards to the
// app or when — that is `test/soniox.test.js`.
//
//   1. a connection that has not started a stream can be held open with `ping`, and
//      every ping is answered (the bridge's idle keepalive and its liveness evidence);
//   2. the start message the bridge builds is accepted as it stands, including
//      `language_hints_strict` with two languages and the `context` block;
//   3. `finalize` followed at once by the empty end-of-stream frame comes back as
//      `<fin>` and/or `finished`, with every token final;
//   4. how long that takes after the last audio — the wait the user feels on release.
//
// Usage:
//   SONIOX_API_KEY=... node server/scripts/soniox-smoke.mjs recording.m4a [--idle 45]
//
// The audio is converted with `afconvert` (macOS) to the 24 kHz mono PCM16 the app
// sends, and paced at wall-clock speed in app-sized chunks, for the same reason
// `script/ab_transcribe.mjs` does both: a burst hands the model the whole sentence up
// front and turns the latency numbers into measurements of nothing.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import WebSocket from "ws";

import { sonioxStartFromSessionUpdate, SONIOX_MODEL } from "../src/soniox-realtime.js";

const ENDPOINT = process.env.SONIOX_REALTIME_URL
  || "wss://stt-rt.soniox.com/transcribe-websocket";
const BYTES_PER_SECOND = 48_000;
const CHUNK_BYTES = 2048;

function fail(message) {
  console.error(`!! ${message}`);
  process.exit(1);
}

function toPCM(file) {
  const wav = join(mkdtempSync(join(tmpdir(), "soniox-smoke-")), "audio.wav");
  try {
    execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", file, wav], {
      stdio: ["ignore", "ignore", "pipe"],
    });
  } catch (error) {
    fail(`afconvert could not read ${basename(file)}: ${error.stderr?.toString().trim() ?? error.message}`);
  }
  const buffer = readFileSync(wav);
  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    if (id === "data") return buffer.subarray(offset + 8, offset + 8 + size);
    offset += 8 + size + (size % 2);
  }
  fail("afconvert produced a WAVE file with no data chunk");
}

const args = process.argv.slice(2);
const idleIndex = args.indexOf("--idle");
const idleSeconds = idleIndex >= 0 ? Number(args.splice(idleIndex, 2)[1]) : 45;
const file = args[0];
const key = process.env.SONIOX_API_KEY?.trim();
if (!key) fail("set SONIOX_API_KEY");
if (!file) fail("usage: soniox-smoke.mjs recording.m4a [--idle seconds]");
if (!Number.isFinite(idleSeconds) || idleSeconds < 0) fail("--idle needs a number of seconds");

const pcm = toPCM(file);
const vocabulary = (process.env.SONIOX_SMOKE_KEYWORDS || "")
  .split(",").map((term) => term.trim()).filter(Boolean);
const start = sonioxStartFromSessionUpdate({
  session: { audio: { input: { transcription: {
    model: SONIOX_MODEL,
    ...(vocabulary.length ? { keywords: vocabulary } : {}),
  } } } },
});

const socket = new WebSocket(ENDPOINT, { headers: { authorization: `Bearer ${key}` } });
const opened = Date.now();
let pongs = 0;
let finalText = "";
let nonFinalText = "";
let firstTokenAt = null;
let finAt = null;
let finishedAt = null;
let audioStartedAt = null;
let committedAt = null;
let nonFinalAfterFin = 0;
let closed = null;

socket.on("message", (data) => {
  const message = JSON.parse(data.toString("utf8"));
  if (message.type === "pong") { pongs += 1; return; }
  if (message.error_code !== undefined) {
    console.error(`!! Soniox error ${message.error_code} ${message.error_type}: ${message.error_message}`);
    return;
  }
  nonFinalText = "";
  for (const token of message.tokens ?? []) {
    if (token.text === "<fin>") { finAt ??= Date.now(); continue; }
    if (token.text === "<end>") continue;
    firstTokenAt ??= Date.now();
    if (token.is_final) finalText += token.text;
    else nonFinalText += token.text;
  }
  if (finAt !== null && nonFinalText.length > 0) nonFinalAfterFin += 1;
  if (message.finished) finishedAt ??= Date.now();
});
socket.on("close", (code, reason) => { closed = { code, reason: reason.toString() }; });
socket.on("error", (error) => fail(`connection failed: ${error.message}`));
await new Promise((resolve) => socket.once("open", resolve));
console.log(`connected in ${Date.now() - opened} ms`);

// 1. Hold the unstarted connection, the way an idle app does all day.
if (idleSeconds > 0) {
  console.log(`holding the unstarted connection for ${idleSeconds} s with a ping every 15 s…`);
  let sent = 0;
  const until = Date.now() + idleSeconds * 1000;
  while (Date.now() < until && closed === null) {
    sent += 1;
    socket.send(JSON.stringify({ type: "ping", id: sent }));
    await sleep(Math.min(15_000, Math.max(0, until - Date.now())));
  }
  if (closed !== null) {
    fail(`Soniox closed the idle connection (${closed.code} ${closed.reason}) — `
      + "the bridge's warm socket would not survive between sentences");
  }
  console.log(`  ${pongs}/${sent} pings answered${pongs === sent ? "" : "  <-- the bridge counts on every one"}`);
}

// 2 + 3. One sentence, exactly as the bridge sends it.
socket.send(JSON.stringify(start));
audioStartedAt = Date.now();
for (let offset = 0; offset < pcm.length && closed === null; offset += CHUNK_BYTES) {
  socket.send(pcm.subarray(offset, offset + CHUNK_BYTES), { binary: true });
  const due = audioStartedAt + ((offset + CHUNK_BYTES) / BYTES_PER_SECOND) * 1000;
  await sleep(Math.max(0, due - Date.now()));
}
socket.send(JSON.stringify({ type: "finalize" }));
socket.send("");
committedAt = Date.now();

const deadline = Date.now() + 15_000;
while (Date.now() < deadline && finishedAt === null && closed === null) await sleep(20);
await sleep(200);

const ms = (at) => (at === null ? "never" : `${at - committedAt} ms after the last audio`);
console.log(`\naudio: ${(pcm.length / BYTES_PER_SECOND).toFixed(1)} s`);
console.log(`first token: ${firstTokenAt === null ? "never" : `${firstTokenAt - audioStartedAt} ms after audio began`}`);
console.log(`<fin>:      ${ms(finAt)}`);
console.log(`finished:   ${ms(finishedAt)}`);
console.log(`non-final tokens after <fin>: ${nonFinalAfterFin}${nonFinalAfterFin ? "  <-- the bridge would drop these" : ""}`);
console.log(`closed by Soniox: ${closed ? `${closed.code} ${closed.reason}` : "no"}`);
console.log(`\ntranscript: ${finalText}${nonFinalText ? `  [still non-final: ${nonFinalText}]` : ""}`);

const problems = [];
if (finAt === null && finishedAt === null) problems.push("neither <fin> nor finished arrived");
if (finalText.trim().length === 0) problems.push("no final text");
if (problems.length) fail(problems.join("; "));
socket.terminate();

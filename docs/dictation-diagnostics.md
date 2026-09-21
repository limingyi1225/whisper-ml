# Local dictation diagnostics

Opt in on the affected Mac, then restart Whisper:

```sh
defaults write com.mingyili.Whisper dictationDiagnosticsEnabled -bool true
```

Disable with the same command and `false`, then restart. This preference is off
by default and is not bundled into releases. Logs contain spoken text; they are
local only, with no audio, credentials, or clipboard snapshots. The directory is
owner-only (0700); files are owner-readable/writable (0600).

Read `~/Library/Logs/Whisper/dictation.jsonl` and
`~/Library/Logs/Whisper/dictation.previous.jsonl`. Each is bounded to 2 MiB; older
records rotate out. Each JSON line includes a process session, utterance UUID,
sequence number, Unix timestamp, and monotonic uptime. Text fields preserve exact
whitespace and include character counts, UTF-16 counts, and CR/LF UTF-16 offsets.
Text over 16,384 characters is explicitly marked truncated.

To investigate misplaced words or unexpected line breaks, follow one utterance:

1. `provider_partial` and `provider_final`: text delivered by the realtime client.
2. `finish_input` and `delivery_final`: after optional cleanup and final formatting.
3. `partial_plan` / `final_rewrite_plan`: believed typed text, shared prefix,
   requested delete count, and the final replacement suffix.
4. `backspace_posted_unverified` / `unicode_chunk_posted_unverified`: events
   actually posted, in order, including every Unicode chunk's exact contents.
5. `ax_*_read` and `final_text_proof` / `final_text_recheck`: results from the
   existing input ownership checks, with `unknown` kept distinct from mismatch.

State events include the target app, frontmost PID, original selection when
available, foreign-input timestamp, keyboard/mouse counters, and injection flags.
An entirely queued utterance starts its diagnostic ID when submitted to the
transcriber; `queued=true` distinguishes this from the real key-release timeline.

Posting is **not** an editor acknowledgement. AX readbacks are observations at
existing proof sites, generally before mutation, not a post-write confirmation.
This instrumentation adds no AX queries, screenshots, key capture, or delivery
retries. An opaque Codex editor can still make the final on-screen result
unreadable: preserve the incorrect text or a screenshot alongside the incident
time. Comparing that against `delivery_final` then separates a transcript error
from a delivery error even when the editor does not expose its text.

Multiline finals use one clipboard paste. `multiline_rewrite_uses_paste` and
`multiline_replacement_proof` precede `paste_replacement_posted_unverified` (the
deleted character count) and `paste_key_posted_unverified`. No Unicode chunks
should follow for that replacement. `paste_deferred` or
`paste_aborted_before_delete` means the previous live text was left intact and
the complete final was retained for clipboard/history recovery.

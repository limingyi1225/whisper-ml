# Claude repository instructions

The authoritative release workflow is in `RELEASING.md`.

When the user says “上传更新”, “发布更新”, or asks to publish/upload a Whisper update,
treat that as authorization for the complete release operation in `RELEASING.md`: inspect
and commit only the intended changes, run `./script/bump_update_version.sh`, validate, then use
`./script/publish_update.sh`. Do not substitute ad-hoc GitHub or appcast commands.

Never include unrelated changes or claim success before the GitHub asset, authoritative
appcast commit, and installed local app have all been verified. The raw GitHub URL has a CDN
TTL: a propagation warning after the commit check is not a failed release and must not cause
a version bump. After application changes, replace and relaunch `/Applications/Whisper.app`
with `./script/install_local.sh`.
If the user explicitly wants to preserve the currently installed older version for an
automatic-update test, publish with `WHISPER_SKIP_LOCAL_INSTALL=1` and verify it stayed old.

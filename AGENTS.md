# Repository instructions

## Publishing application updates

Read and follow `RELEASING.md` whenever the user says “上传更新”, “发布更新”, or asks to
publish/upload a Whisper update. Those phrases authorize the complete release operation
described there, including intentional commits, pushes, the GitHub Release, asset upload,
and appcast publication. Use `./script/publish_update.sh`; do not improvise a second flow.

Always inspect the exact worktree and commit scope first. Never include unrelated user
changes, reuse an already-published version/build for new source, publish from a dirty tree,
or report an update as live before both the release asset and exact appcast commit have been
verified. A raw GitHub CDN propagation warning after that authoritative check is not a
publication failure; rerun the same version to verify it, never increment just for the CDN.
For a new release, run `./script/bump_update_version.sh` before tests and the source commit;
it advances a published pair and leaves an already-unpublished pair unchanged.

After changing the application, run `./script/install_local.sh` so the Developer ID-signed
Release build replaces `/Applications/Whisper.app` and is relaunched. Verify the process.
The sole exception is an explicit request to preserve the older installed version for a real
automatic-update test; publish with `WHISPER_SKIP_LOCAL_INSTALL=1` and verify it stayed old.

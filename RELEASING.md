# Publishing a Whisper update

This is the single source of truth for human operators, Codex, and Claude.

When the user says **“上传更新”**, **“发布更新”**, or **“publish the update”**, that is
explicit authorization to publish the intended Whisper changes: commit them, push `main`,
create the GitHub Release, upload the signed update, and publish the appcast. It does not
authorize including unrelated local changes.

## Agent workflow

1. Inspect `git status`, staged/unstaged/untracked changes, and the diff. Separate unrelated
   user work rather than sweeping it into the release.
2. Run the relevant tests and release checks.
3. Check `updates/appcast.xml`. If the current `MARKETING_VERSION` or
   `CURRENT_PROJECT_VERSION` was already published, increment both in the Whisper target.
   Version choice is a product decision; do not silently reuse a published version.
4. Commit only the intended release changes on `main`. The publishing script deliberately
   refuses a dirty worktree.
5. Run:

   ```bash
   ./script/publish_update.sh path/to/release-notes.md
   ```

   The notes argument is optional. Without it, GitHub generates release notes.
6. Report the version/build, GitHub Release URL, appcast URL, test results, installed
   `/Applications/Whisper.app` status, and raw CDN propagation result. Do not claim success
   unless the release asset, authoritative appcast commit, and local process were verified;
   a still-stale anonymous raw URL is a propagation warning, not a publication failure.

## What the script guarantees

The script requires authenticated `gh`, a clean up-to-date `main`, the release Mac's
notarization credentials, and Sparkle's EdDSA private key in Keychain. It then:

1. Pushes the reviewed source commit and checks it out in an immutable detached worktree.
2. Builds, signs, notarizes, and verifies the public universal DMG from that exact commit.
3. Generates and verifies the signed Sparkle appcast.
4. Creates the GitHub Release and uploads the DMG.
5. Confirms the public asset URL works.
6. Installs and launches the same released source locally.
7. Commits and pushes `updates/appcast.xml` last, then reads that exact immutable commit
   through the authenticated GitHub Contents API.
8. Polls the anonymous raw feed through its five-minute CDN TTL. A matching response is
   confirmed; a still-stale CDN response is reported as a warning after the exact appcast
   commit and release asset have already been authoritatively verified.

Publishing the appcast last is the safety boundary: a failed run may leave an unused
GitHub Release, but installed apps never receive a feed pointing to a missing download.

If a retry finds an existing release, it re-verifies the retained appcast, its enclosure
signature and metadata, and continues only when the remote DMG is byte-for-byte identical.
It never replaces a public binary in place. If the final appcast push fails, or the completed
run reports a raw CDN propagation warning, rerun the same publishing script without changing
the version. It recognizes the exact release-tag → source-commit → appcast-commit chain,
finishes or verifies the final push, and exits successfully. Incrementing the version in this
state would create a false second release and is explicitly wrong.

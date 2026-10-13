# curl-impersonate-fil-c Agent Guide

This repository is a downstream packaging fork of
`lexiforest/curl-impersonate`. Its purpose is to carry one downstream change:
the Fil-C Docker build and the minimum compatibility/CI wiring required for
that build.

## Non-Negotiable Invariants

1. `upstream` is `lexiforest/curl-impersonate`; `origin` is
   `cfal/curl-impersonate-fil-c`.
2. Never push to `upstream` and never open a PR against the upstream project.
   Upgrade PRs belong in `cfal/curl-impersonate-fil-c` only.
3. Outside an open upgrade PR, `origin/main` must be exactly one non-merge
   commit above `upstream/main`:

   ```sh
   test "$(rtk git rev-parse origin/main^)" = "$(rtk git rev-parse upstream/main)"
   test "$(rtk git rev-list --count upstream/main..origin/main)" -eq 1
   ```

4. While an upgrade PR is open, `origin/main` temporarily equals
   `upstream/main`, and the PR head is exactly one commit above both.
5. **Always squash-merge every upgrade PR.** Keep all downstream work in the
   PR's one commit; during review, amend it and force-push with a lease instead
   of stacking fixup commits. Never use a merge commit or rebase-merge.
6. Use `--force-with-lease` with an explicit expected SHA for rewritten
   branches. Never use an unguarded `--force`.
7. The worktree must be clean before any rebase, branch rewrite, merge, or tag.
   Do not discard changes that may belong to the user.
8. Do not modify the inherited top-level `patches/` directory. If an upgrade
   appears to require such a change, stop and ask the user. Changes under
   `docker/patches/` are Fil-C-specific and may be adapted when necessary.
9. Prefix shell commands with `rtk` in agent environments configured with the
   repository's RTK instructions.

## Repository Shape

- `CMakeLists.txt`: dependency superbuild and Fil-C build switches.
- `docker/debian.dockerfile` and `docker/alpine.dockerfile`: Fil-C builders and
  runtime images.
- `docker/patches/`: narrowly scoped Fil-C compatibility patches.
- `patches/`: inherited curl-impersonate patches; do not edit downstream.
- `.github/workflows/build-docker.yml`: Fil-C Docker validation, downloadable
  artifact packaging, GitHub releases, and optional Docker Hub publishing.
- `.github/workflows/build.yml`, `build-win.yaml`, and `test.yml`: inherited
  cross-platform CI and signature validation; their outputs are not Fil-C
  release artifacts.

## Upgrade Runbook

### 1. Establish a Clean, Correct Starting Point

Verify remotes and refuse to continue with a dirty worktree:

```sh
rtk git status --short
test -z "$(rtk git status --porcelain)"
rtk git remote -v
rtk gh auth status
rtk git fetch --prune origin
rtk git fetch --prune upstream
```

Expected remotes:

```text
origin    github.com/cfal/curl-impersonate-fil-c
upstream  github.com/lexiforest/curl-impersonate
```

If `upstream` is missing, add it as
`https://github.com/lexiforest/curl-impersonate.git` before fetching. If either
remote points at a different repository, stop rather than guessing which
repository is safe to rewrite.

Record the current downstream commit before rewriting anything:

```sh
fork_tip=$(rtk git rev-parse origin/main)
old_base=$(rtk git rev-parse "${fork_tip}^")
parents=$(rtk git show -s --format=%P "$fork_tip")
case "$parents" in *" "*) exit 1 ;; esac
test "$(rtk git rev-list --count "${old_base}..${fork_tip}")" -eq 1
rtk git merge-base --is-ancestor "$old_base" upstream/main
```

If the current downstream tip is a merge commit, contains multiple downstream
commits, or is not based on an ancestor of current upstream, stop and inspect
the history instead of guessing.

### 2. Rebase the Single Downstream Change

Use a unique branch outside the workflow's `feature/*` push pattern. This
avoids running the full matrix once for the push and again for the PR.

```sh
branch="fil-c/upgrade-$(rtk date -u +%Y%m%d-%H%M%S)"
rtk git switch -C "$branch" "$fork_tip"
rtk git rebase --onto upstream/main "$old_base"
```

Resolve conflicts only in the downstream Fil-C delta. Take upstream's version
of unrelated files. Never resolve a conflict by changing top-level `patches/`;
ask the user if that becomes necessary.

Immediately verify the rebased shape:

```sh
test "$(rtk git rev-parse HEAD^)" = "$(rtk git rev-parse upstream/main)"
test "$(rtk git rev-list --count upstream/main..HEAD)" -eq 1
rtk git diff --quiet upstream/main -- patches
```

### 3. Check and, When Needed, Update Fil-C

Both Dockerfiles must pin the same released compiler version and SHA-256. Find
the currently pinned version and the latest upstream Fil-C release:

```sh
rtk rg -n '^ARG FILC_(VERSION|SHA256)=' docker/*.dockerfile
rtk gh api repos/pizlonator/fil-c/releases/latest \
  --jq '{tag: .tag_name, published: .published_at, assets: [.assets[].name]}'
```

Read the Fil-C release notes before updating. If a newer suitable Linux
x86_64 compiler exists, download the exact release asset to a temporary
directory and calculate its checksum rather than copying a checksum from an
untrusted page:

```sh
tmp=$(rtk mktemp -d)
version="0.xxx" # Replace with the release version without the leading v.
rtk gh release download "v${version}" --repo pizlonator/fil-c \
  --pattern "filc-${version}-linux-x86_64.tar.xz" --dir "$tmp"
rtk sha256sum "$tmp/filc-${version}-linux-x86_64.tar.xz"
```

Update `FILC_VERSION` and `FILC_SHA256` in both Dockerfiles together. If
`/fil-c-utils/curl/Dockerfile` is available, compare its current compiler setup,
static-link flags, provenance checks, CA handling, and known compatibility
workarounds. Treat it as a reference, not as source to copy blindly.

Upstream dependency revisions may make `docker/patches/*.patch` fail or become
obsolete. Keep those patches minimal and Fil-C-specific. Prefer removing an
obsolete workaround or using an upstream build option over expanding a patch.

After every rebase or fix, preserve the single-commit invariant:

```sh
rtk git add path/to/intended-file
rtk git commit --amend --no-edit
test "$(rtk git rev-list --count upstream/main..HEAD)" -eq 1
rtk git diff --quiet upstream/main -- patches
```

### 4. Validate Locally

At minimum, run all of the following before opening the PR:

```sh
rtk git diff --check upstream/main...HEAD -- . \
  ':(exclude)docker/patches/*.patch'
rtk cmake -S . -B /tmp/curl-impersonate-cmake-check -DUSE_LIBIDN2=OFF
rtk docker build --check -f docker/debian.dockerfile .
rtk docker build --check -f docker/alpine.dockerfile .
rtk docker build --progress=plain -f docker/debian.dockerfile \
  -t curl-impersonate-fil-c:debian .
rtk docker build --progress=plain -f docker/alpine.dockerfile \
  -t curl-impersonate-fil-c:alpine .
artifact_dir=$(rtk mktemp -d)
rtk docker build --progress=plain --target artifact \
  --output "type=local,dest=${artifact_dir}" \
  -f docker/debian.dockerfile .
rtk nm -a "${artifact_dir}/bin/curl-impersonate" > /tmp/curl-impersonate.nm
rtk rg '[[:space:]][Tt][[:space:]]+filc_' /tmp/curl-impersonate.nm
```

The `docker/patches/*.patch` exclusion is deliberate: unified-diff context
lines begin with a space, so blank context lines look like trailing whitespace
to `git diff --check`. The patches are still exercised by both Docker builds.

Smoke-test both runtime images:

```sh
rtk docker run --rm curl-impersonate-fil-c:debian \
  curl-impersonate --version
rtk docker run --rm curl-impersonate-fil-c:debian \
  curl-impersonate --fail --silent --show-error --output /dev/null \
  https://github.com/
rtk docker run --rm curl-impersonate-fil-c:debian \
  curl_chrome136 --fail --silent --show-error --output /dev/null \
  https://github.com/
rtk docker run --rm curl-impersonate-fil-c:alpine \
  curl-impersonate --version
rtk docker run --rm curl-impersonate-fil-c:alpine \
  curl-impersonate --fail --silent --show-error --output /dev/null \
  https://github.com/
rtk docker run --rm curl-impersonate-fil-c:alpine \
  curl_chrome136 --fail --silent --show-error --output /dev/null \
  https://github.com/
```

The Dockerfiles themselves must continue to gate on static PIE linkage, no
ELF interpreter, retained Fil-C symbols, no unresolved `@llvm.` strings, and a
verified real HTTPS request. Do not weaken those checks to make a build pass.

Remove temporary build/check directories after validation. Do not commit
generated build output.

### 5. Reset Fork Main and Open the Internal PR

Fetch upstream once more in case it moved during local validation. If it did,
rebase the single commit again and repeat affected tests.

Push the feature branch first so the downstream commit is safely stored, then
reset fork `main` to the exact upstream tip using an explicit lease:

```sh
rtk git push -u origin "$branch"
expected_main=$(rtk git rev-parse origin/main)
rtk git push \
  --force-with-lease="refs/heads/main:${expected_main}" \
  origin upstream/main:refs/heads/main
rtk git fetch origin main
test "$(rtk git rev-parse origin/main)" = "$(rtk git rev-parse upstream/main)"
```

Open the PR **inside this fork**, never against `lexiforest`:

```sh
rtk gh pr create --repo cfal/curl-impersonate-fil-c \
  --base main --head "$branch" \
  --title "Build Docker images with Fil-C" \
  --body-file /tmp/curl-impersonate-fil-c-pr.md
```

The PR body must state:

- the upstream commit being rebased onto;
- the old and new Fil-C versions, or that the pin was checked and unchanged;
- compatibility changes and affected dependencies;
- exact local verification commands and results;
- that top-level `patches/` is unchanged.

### 6. Keep the PR at One Commit and Get CI Green

For every review or CI fix, first make sure nobody else updated the remote PR
branch, then amend and force-push against that exact tip:

```sh
rtk git fetch origin "refs/heads/${branch}:refs/remotes/origin/${branch}"
expected_branch=$(rtk git rev-parse "origin/${branch}")
test "$(rtk git rev-parse HEAD)" = "$expected_branch"
rtk git add path/to/intended-file
rtk git commit --amend --no-edit
rtk git push \
  --force-with-lease="refs/heads/${branch}:${expected_branch}" \
  origin "HEAD:refs/heads/${branch}"
```

Then re-check:

```sh
test "$(rtk git rev-parse HEAD^)" = "$(rtk git rev-parse upstream/main)"
test "$(rtk git rev-list --count upstream/main..HEAD)" -eq 1
rtk git diff --quiet upstream/main -- patches
```

Required PR workflows are:

- Fil-C Debian and Alpine Docker builds;
- Linux, macOS, BSD, Android, and iOS build matrix;
- Windows build matrix;
- signature/integration tests.

Use `rtk gh pr checks`/`rtk gh run view --log-failed` to diagnose failures.
Fix root causes in the single downstream commit; do not merge around a failing
relevant check.

### 7. Recheck Upstream and Always Squash-Merge

Immediately before merge, confirm upstream did not advance while CI ran:

```sh
rtk git fetch --prune upstream
rtk git fetch --prune origin
test "$(rtk git rev-parse origin/main)" = "$(rtk git rev-parse upstream/main)"
```

If that equality fails, rebase the PR commit onto the new upstream tip,
force-update fork `main` with a lease, force-update the PR branch with a lease,
and let CI run again.

When every required check is green, use **Squash and merge** and delete the
remote branch. This is the only permitted merge method: do not use a merge
commit or rebase-merge, even though the PR already contains one commit.

```sh
PR_NUMBER=$(rtk gh pr view "$branch" --repo cfal/curl-impersonate-fil-c \
  --json number --jq .number)
rtk gh pr merge "$PR_NUMBER" --repo cfal/curl-impersonate-fil-c \
  --squash --delete-branch
rtk git fetch --prune origin
rtk git fetch --prune upstream
```

Verify the published history before releasing:

```sh
test "$(rtk git rev-parse origin/main^)" = "$(rtk git rev-parse upstream/main)"
test "$(rtk git rev-list --count upstream/main..origin/main)" -eq 1
```

If either assertion fails, do not tag a release.

## Release Runbook

### 1. Choose a New Tag

Base the name on the nearest upstream release reachable from `upstream/main`:

```sh
upstream_tag=$(rtk git describe --tags --abbrev=0 upstream/main)
rtk git tag -l "${upstream_tag}-filc.*" --sort=-v:refname
rtk git ls-remote --tags origin "refs/tags/${upstream_tag}-filc.*"
```

Use the next unused `${upstream_tag}-filc.N` value. Start at `.1` for a new
upstream release and increment `N` for another Fil-C release on the same
upstream version. Never reuse or force-move a published release tag.

### 2. Tag the Verified Main Commit

Synchronize local `main` only from the verified remote tip, then tag it:

```sh
rtk git switch -C main origin/main
release_tag="${upstream_tag}-filc.N" # Replace N with the next unused number.
rtk git tag -a "$release_tag" origin/main \
  -m "Fil-C Docker build ${release_tag}"
rtk git push origin "refs/tags/${release_tag}"
test "$(rtk git rev-list -n1 "$release_tag")" = "$(rtk git rev-parse origin/main)"
```

Pushing the tag starts `.github/workflows/build-docker.yml`. The workflow
builds both runtime images, exports the Docker builder's verified `artifact`
stage, packages it, and publishes the tarball and SHA-256 file to GitHub.

### 3. Monitor and Audit Publication

Monitor the tag-triggered workflow through completion:

```sh
RUN_ID="replace-with-build-run-id"
rtk gh run list --repo cfal/curl-impersonate-fil-c \
  --workflow build-docker.yml --branch "$release_tag"
rtk gh run watch "$RUN_ID" \
  --repo cfal/curl-impersonate-fil-c --exit-status
```

The release is complete only when:

- every release job succeeds;
- both Fil-C Docker images build successfully;
- the GitHub release exists, is published, and is not a draft;
- `curl-impersonate-${release_tag}.x86_64-linux-filc.tar.gz` and its `.sha256`
  file are attached;
- the downloaded archive passes its checksum, and running `nm -a` on
  `bin/curl-impersonate` displays defined `filc_*` symbols;
- release notes describe the upstream base, Fil-C version, and validation.

Audit with:

```sh
rtk gh release view "$release_tag" \
  --repo cfal/curl-impersonate-fil-c \
  --json tagName,isDraft,isPrerelease,publishedAt,url,assets,body
```

Do not attach artifacts from the inherited cross-platform workflows to a Fil-C
release: those use native/Zig toolchains. The downloadable Fil-C tarball must
always come from the Dockerfile's `artifact` stage. When `DOCKER_USERNAME` and
`DOCKER_TOKEN` repository secrets are configured, the tag workflow also
publishes the runtime images to Docker Hub. Without those secrets, it still
builds and validates the images and publishes the GitHub tarball, but skips
registry publication; call this out in the release notes.

## Final Handoff Checklist

- Fork PR, never upstream PR, was squash-merged; no other merge method is used.
- `origin/main^` exactly equals `upstream/main`.
- `origin/main` is exactly one commit ahead.
- Top-level `patches/` has no downstream diff.
- Fil-C version and SHA-256 match in both Dockerfiles.
- Local Docker tests and all required CI workflows passed.
- A new immutable `-filc.N` tag points to `origin/main`.
- GitHub release has the Fil-C tarball and checksum, and no native/Zig archives.
- The released executable exposes defined `filc_*` symbols through `nm -a`.
- Docker publication status is reported accurately.
- No required workflow remains running.
- Worktree is clean and local `main` tracks `origin/main`.

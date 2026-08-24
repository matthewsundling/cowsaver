# Releasing Cowsaver

This procedure is for the maintainer publishing a release. It records the release state
transitions; [the macOS compatibility checklist](release-checklist.md) records field evidence
and does not replace this procedure.

## 1. Record the release decisions

Before preparing the release, record the product bundle version (for example, `1.1.0`), the tag
and GitHub release name (for example, `1.1`), the supported-version policy that will appear in
`SECURITY.md`, and the release notes derived from the changelog. Distribution is source-only:
GitHub generates source archives, but the release has no manually attached assets or binary assets.

## 2. Prepare the release pull request

Create a release-preparation pull request that reconciles:

- `Makefile` `VERSION`, which supplies both products' `CFBundleShortVersionString` and
  `CFBundleVersion`;
- the changelog version and date;
- `SECURITY.md` supported-version policy; and
- compatibility wording with the available field evidence.

Do not describe Tahoe as supported while its open issues still lack direct field evidence. Use
the [macOS compatibility checklist](release-checklist.md) to obtain and record that evidence.

## 3. Validate the exact candidate commit from a clean tree

Check out the exact candidate commit in a clean tree. Replace `<candidate-commit>` below with its
full commit identifier where shown.

```sh
git status --short
git rev-parse HEAD
make clean
make check
make test
make smoke
make test-diagnostics
make saver
make app
plutil -p build/Cowsaver.saver/Contents/Info.plist
plutil -p build/Cowsaver.app/Contents/Info.plist
test -f build/Cowsaver.saver/Contents/Resources/cows/license.txt
test -f build/Cowsaver.saver/Contents/Resources/cows/provenance.md
test -f build/Cowsaver.saver/Contents/Resources/fortune-curated/license.txt
test -f build/Cowsaver.saver/Contents/Resources/fortune-curated/provenance.md
test -f build/Cowsaver.app/Contents/Resources/cows/license.txt
test -f build/Cowsaver.app/Contents/Resources/cows/provenance.md
test -f build/Cowsaver.app/Contents/Resources/fortune-curated/license.txt
test -f build/Cowsaver.app/Contents/Resources/fortune-curated/provenance.md
git archive --format=tar <candidate-commit> | tar -tf
git status --short
```

`make clean` removes previous `.build` and `build` artifacts before validation. Confirm that
`make check` passes the source boundaries; `make test` passes the full Swift Testing suite;
`make smoke` passes the separate framework-free 219-fixture cowsay-byte check; and
`make test-diagnostics` passes the diagnostic-tool tests. Confirm that both products build, both
plists show the intended short and bundle versions, every listed bundled notice is present, the
source archive contains the intended tracked source and documentation, and the final status has
not changed tracked release contents.

## 4. Wait for pull-request checks and synchronize the candidate

Require all four current GitHub checks on the release-preparation pull request: the macOS 14,
macOS 15, and current macOS build jobs, plus the cowsay 3.8.4 fidelity job. After merging, update
the local checkout to the exact merged commit and repeat the clean-tree validation above before
creating the tag.

## 5. Create and verify the signed tag

Create an annotated signed tag from the merged commit, using the recorded tag spelling:

```sh
git tag -s 1.1 -m "Cowsaver 1.1" <merged-commit>
git verify-tag 1.1
git show --no-patch 1.1
git push origin 1.1
```

Replace the example version and commit with the recorded release values. Verify locally that the
tag is annotated, signed, and points to the merged commit before pushing it.

## 6. Publish the GitHub release

Create a GitHub release named `1.1` for the pushed tag. Its notes must agree with the merged
changelog. Keep the release source-only; GitHub supplies source archives, and do not manually
attach assets or binary assets.

## 7. Verify the published release

Verify the published tag and release, download and inspect the source archive, and confirm the
version metadata and bundled notices in a fresh build. When the recorded compatibility evidence
requires it, perform a fresh install or the documented compatibility run and record its result in
the [macOS compatibility checklist](release-checklist.md).

Unresolved Tahoe issues prevent a Tahoe support claim. The compatibility checklist supplies the
needed macOS field evidence; it is not a substitute for the release steps above.

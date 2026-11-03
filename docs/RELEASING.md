# Versioning and Releases

Use [Semantic Versioning 2.0.0](https://semver.org/) with annotated Git tags of the form `vMAJOR.MINOR.PATCH`.
The initial working prototype is `v0.1.0`. Version numbers have no leading `v` in the changelog; Git tags do.

## Compatibility policy

The public interface comprises command options, exit behavior, documented configuration, and terminal output behavior.
During `0.x`, use a new minor version for incompatible interface changes and substantial new capabilities; use a patch
version for compatible fixes and documentation corrections. At `1.0.0`, use major versions for incompatible changes,
minor versions for compatible functionality, and patch versions for compatible fixes.

Rendering corrections can change captured output, so describe them explicitly. Distinguish intended fixes from
changes that require consumers to alter configuration or invocation.

## Release checklist

Every version listed in the changelog is released on its own: one release commit and one annotated tag. Do
not stack several unreleased versions in the working tree; if that happens, merge them into one changelog
section and release them under a single version.

1. Review [TODO.md](../TODO.md), complete applicable validation, and inspect the diff for generated/private files.
2. Run `just check-dev`, then the whole portable suite with `just test` (`bats tests/`), and `tests/nvim-versions`
   for the supported released Neovim versions; every test must pass.
   Note any skips (fzf, rg, script or Neovim versions not installed) in the release commit message.
3. Run `benchmarks/run` and check the SYNTAX.md table for regressions against the averages.
4. Update [CHANGELOG.md](../CHANGELOG.md): move the `[Unreleased]` entries under the new version and date,
   describe every user-visible change (behavior, options, output, errors), and state the known limitations
   that remain. `VERSION` holds the same number (`bats tests/version.bats` checks both).
5. Ensure `nvcat --version` agrees with the tag (`bats tests/version.bats` checks a tagged HEAD).
6. Commit the release contents on the intended branch.
7. Create an annotated tag, then push the branch and that exact tag together:

```sh
git tag -a v0.1.0 -m "Release v0.1.0: initial Markdown renderer"
git push --atomic origin main refs/tags/v0.1.0
```

Choose the next version for later releases. Do not move a published tag or force-push a replacement; release a
new version containing the correction. A GitHub Release or distributable package is separate from the Git tag.

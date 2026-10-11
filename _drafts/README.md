# _drafts

Work-in-progress posts. **Nothing in here is tracked by git except this file.**

## Why the underscore matters

Jekyll skips any top-level directory beginning with `_`. A folder named
`drafts/` (no underscore) gets **built and published** — a post sitting in it
goes live the moment you push. `_drafts/` does not.

## Why the .gitignore entry matters too

This repository is **public on GitHub**. Keeping a post out of the built site
does not keep it out of the repo — a committed draft is readable by anyone at
github.com, just not rendered at the domain. So `_drafts/*` is gitignored and
only this README is committed.

Local-only does NOT mean unbacked-up, as of 2026-10-11. `sites-backup.sh`
(LaunchAgent `com.imacdude.sites-backup`, 01:30 daily) mirrors all of `~/Sites`
-- this directory included -- to `/Volumes/Data/backups/sites`, and the 02:00
rsync carries that to the Pi5. So a draft in progress has an off-host copy
within hours, without ever entering this public repo.

What is still true: a draft is **not in git**, so there is no history and no
diff against an earlier version of itself -- only the latest mirrored copy.
Keep a draft here *before* handing its text to anything that might rewrite it;
that is what `blog-diff.py --against` compares against.

## Previewing a draft

```sh
jekyll serve --drafts        # thebelens.com needs JEKYLL_NO_BUNDLER_REQUIRE=true
```

## Publishing

```sh
git mv _drafts/YYYY-MM-DD-slug.md _posts/     # will not work — drafts are untracked
mv _drafts/YYYY-MM-DD-slug.md _posts/ && git add _posts/YYYY-MM-DD-slug.md
```

Before publishing a post with a photo, run the image pipeline in
`~/Sites/CLAUDE.md` — strip EXIF, confirm GPS count is zero, resize, and
**look at the image**.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Baotiao's personal technical blog at <https://baotiao.github.io>, served from GitHub Pages. Jekyll site using the `minima` theme with custom overrides. Almost all content is database-kernel writeups (InnoDB, PostgreSQL, PolarDB, DuckDB, MySQL upstream) plus a long tail of older personal posts going back to 2011.

The site is content-first: ~150 posts in `_posts/`, very little template code. Most of "this repo" is markdown.

## Local development

```bash
bundle install              # first time only
bundle exec jekyll serve    # http://127.0.0.1:4000, live reload
bundle exec jekyll build    # one-shot build into _site/
```

No CI, no tests, no linter. GitHub Pages builds master directly. `_site/` and `.sass-cache/` are local-only.

## Authoring a new post

File path: `_posts/YYYY-MM-DD-slug.md`. Frontmatter that recent posts use:

```yaml
---

layout: post
title: <title — Chinese or English, no quotes needed unless it contains ':'>
summary: <one or two sentences shown on listing pages and in <head>>

---
```

Notes that match the existing pattern, not Jekyll defaults:

- `summary:` is custom (not Jekyll's standard `excerpt`/`description`) — keep it, the layout/SEO relies on it.
- `date:` is not required when it's encoded in the filename. Only some old posts set it explicitly.
- `tags:` default to `Other` via `_config.yml`. Set tags only if grouping a post on `archive.md` matters.
- Kramdown syntax highlighting is disabled in `_config.yml` — fenced code blocks are styled at runtime by **highlight.js**, not at build time. Use the language hint after the backticks (` ```c `, ` ```sql `, ` ```diff `).

## Code-highlight stack

`_includes/head.html` loads `highlight.js` plus a curated set of language packs (`c`, `cpp`, `python`, `bash`, `sql`, `diff`, `json`, `go`, `rust`, `javascript`, `tsql`, `powershell`, `plaintext`). The current stylesheet is `js/highlightjs/styles/mono.css` (a vim-default-dark monochrome palette — see recent commits).

If a post uses a new language, add the corresponding `languages/<lang>.min.js` to `_includes/head.html`. Switching themes = change the one `<link rel="stylesheet">` line in `head.html`; alternative styles already vendored: `default.css`, `github.css`, `ssms.css`.

`css/override.css` is loaded only on post pages (via `_layouts/post.html`) and handles `<hr>` spacing and the prev/next post navigation. The minima `pre` background tweak for the mono theme lives there too.

## Layout customizations vs upstream minima

- `_layouts/post.html` — overridden to add share links (`_includes/sharelinks.html`) above the post body and prev/next navigation (`_includes/navlinks.html`) at the bottom, plus the `override.css` link. Default `minima` doesn't have these.
- `_includes/head.html` — overridden so highlight.js is global (every page, not just posts).
- `_layouts/default.html` is **not** overridden — it comes from the minima gem.

When upgrading the minima theme, diff these three files; any other layout is untouched.

## Writing-style conventions (apply when drafting or editing posts)

The user's global preferences in `~/.claude/CLAUDE.md` already cover most of this, but these are the blog-specific points that show up consistently in recent posts:

- Chinese prose with **English punctuation** and a single space after `, . :` — never `，。：`.
- Headings start at `####` only (the `<h1>` is generated from frontmatter `title`).
- Bilingual where useful: function names, file paths, type names stay in English inline (e.g. `PinBuffer`, `buf_page_t::buf_fix_count`, `src/backend/storage/buffer/README`).
- `summary:` is a thesis sentence, not a teaser — it should state the claim the post argues.
- Tone is engineering-notebook: function-level, code-path-level, no marketing voice.

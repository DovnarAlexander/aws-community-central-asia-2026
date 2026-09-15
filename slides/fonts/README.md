# Deck fonts

DM Sans and Fira Code, the two families the `naviteq-slidev` theme asks for. Vendored here
so the deck keeps its typography at a venue with no internet — the `@font-face` rules are in
`../style.css`, and `talk.md` sets `fonts.provider: none` so Slidev does not add the Google
Fonts stylesheet on top of them.

Both are variable fonts, so one file covers every weight the deck uses and there is no
per-weight subset to keep in sync. Two subsets each, `latin` and `latin-ext`, which is all of
an English deck. Taken from the Google Fonts CDN and unchanged. Both are licensed under the
SIL Open Font License 1.1:

- DM Sans — https://github.com/googlefonts/dm-fonts
- Fira Code — https://github.com/tonsky/FiraCode

The theme's own stylesheet still carries an `@import` of DM Sans from Google Fonts. It is
harmless: the faces defined here are loaded from disk and win, and the request simply fails
when there is nothing to answer it.

To refresh them, fetch the `css2` stylesheet for both families with a modern browser user
agent, download the woff2 files it points at, and keep the file naming used here.

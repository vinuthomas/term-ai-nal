# Bundled font

**JetBrainsMonoNL Nerd Font Mono** — the four faces in this directory are
shipped inside the app bundle and registered at launch via
`ATSApplicationFontsPath`, so the default terminal font is correct on a machine
with no Nerd Font installed. No system installation happens; registration is
scoped to the app.

Why this exact build:

- **NL (no ligatures).** SwiftTerm shapes text with
  `CTLineCreateWithAttributedString`, and CoreText applies ligatures by default.
  In a cell-addressed grid a ligature spanning two cells risks column and
  selection misalignment, so the no-ligature build removes the question. The
  ligature build is a drop-in swap if that is ever wanted.
- **Mono.** Nerd Fonts ship icons at double width by default, which overflow a
  terminal cell and shift everything after them. The `Mono` builds force
  single-width glyphs.

## Licensing

- **JetBrains Mono** (the base typeface) — SIL Open Font License 1.1, see
  `OFL.txt`. Permits bundling in an application, commercially or otherwise.
- **Nerd Fonts patching** — the icon glyphs added on top are aggregated by the
  Nerd Fonts project (MIT) from several upstream icon sets under a mix of
  licences, including some that require attribution (Font Awesome is CC BY 4.0).
  This notice serves that purpose. The authoritative per-set list is at
  https://github.com/ryanoasis/nerd-fonts — consult it before shipping to
  anyone outside this repo.

Source: Nerd Fonts v3.4.0, `JetBrainsMono.zip`.

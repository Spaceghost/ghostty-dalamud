# Glyphs: what draws what, and why

A terminal has to draw whatever bytes a program writes. Four things draw it
here, in this order, and every code point ends at one of them:

1. **Shapes** — `core/boxdraw.nelua` draws box drawing (U+2500–U+257F), block
   elements (U+2580–U+259F), braille (U+2800–U+28FF) and the powerline
   separators (U+E0B0–U+E0BF) as filled rectangles and triangles. They must
   touch their neighbours exactly, which no font guarantees at a fractional
   cell size.
2. **The ImGui terminal font** — Inconsolata, with the Nerd Font symbols, Noto
   Sans Symbols 2 and Dalamud's Noto Sans CJK merged behind it over the ranges
   in `shim/GhosttyDalamud/HostApi.cs`.
3. **The fallback atlas** — `core/glyphfb.nelua` rasterizes a glyph with
   stb_truetype into a 1024×1024 texture of the core's own on Dalamud's D3D11
   device and draws it as an image tinted by the cell's foreground colour.
4. **The tofu box** — a hollow rectangle, with the code point's hex digits in
   it where they fit, for a code point that is in no font at all.

## Why an atlas of our own at all

Dalamud's ImGui is built with 16-bit `ImWchar`. A code point above U+FFFF can
therefore never be in an ImGui font: ImGui decodes the UTF-8 and gets U+FFFD.
That rules out emoji (U+1F300–U+1FAFF), the Nerd Font Material Design icons
(U+F0000 and up) and CJK Extension B (U+20000 and up) no matter which font is
merged, so those need a rasterizer of ours. Having one, the same path also
covers BMP glyphs the merged font happens to lack.

`glyphfb_wants` decides, per code point: everything above U+FFFF, plus a BMP
code point the ImGui font has no glyph for. The BMP half asks cimgui. The
Dalamud cimgui.dll in `~/.xlcore/dalamud/Hooks/15.0.3.5/` exports
`ImFont_FindGlyphNoFallback` (verified against its PE export table: 1285
exports, both `ImFont_FindGlyph` and `ImFont_FindGlyphNoFallback` among them),
which answers directly. Should some build not export it, `ImFont_FindGlyph`
answers as well: it returns the font's *fallback* glyph for a code point the
font lacks, so a glyph that is the same pointer as the one U+0001 resolves to
(a control code no built ImGui font can hold) is a missing glyph. With neither
export, BMP glyphs stay with the ImGui font, as before.

## The fallback font chain

In order, from the plugin's `fonts/` directory (`fonts/README.md`):

| Font | For | Size |
| --- | --- | --- |
| `SymbolsNerdFontMono-Regular.ttf` | Nerd Font icons, 10,410 code points | 2.5 MB |
| `NotoSansSymbols2-Regular.ttf` | symbols, arrows, geometric shapes, 2,641 code points | 0.67 MB |
| `NotoEmoji[wght].ttf` | monochrome emoji, 1,489 code points, 1,300 of them above U+FFFF | 1.98 MB |
| the host's CJK font | ideographs, kana, Extension B | 19.5 MB, not shipped |

Each file is read on the first glyph the files before it do not have, and never
sooner, so the resident cost is what the session actually shows: a prompt full
of Nerd Font icons reads 2.5 MB and nothing else. A code point in no font is
the one case that reads them all, and it is cached as missing so it happens
once.

The host's CJK font is whatever Dalamud has already downloaded — the shim
answers `game_string("cjk_font")` with the first of
`UIRes/NotoSansCJK-Regular.ttc`, `UIRes/NotoSansCJKjp-Medium.otf`,
`UIRes/NotoSansKR-Regular.otf` that exists, and `core/app/lifecycle.nelua`
hands that path to `glyphfb_add_font`. stb_truetype reads its CFF outlines and
its TrueType collection header (subfont 0) without help. No system font path is
hardcoded: on a machine where Dalamud's assets are missing, CJK falls through
to the tofu box rather than to a guess.

## Why CJK is not merged into the ImGui font instead

| | merged into the ImGui atlas | the fallback atlas |
| --- | --- | --- |
| CJK unified ideographs (U+4E00–U+9FFF) | 20,992 glyphs; at a 16 px cell ImGui packs them at about 19×19 px = 7.6 M pixels, which forces a 4096×2048 atlas — **32 MB of texture**, per font handle (the terminal font and the world font are two), rasterized at build time on every font-size change | 0 extra bytes: the 4 MB 1024×1024 atlas already exists, and holds about 3,100 glyphs of an 18×18 slot at once — roughly three screens full, since an 80×24 screen has room for only 960 double-width characters |
| CJK Extension B (U+20000+) | impossible: 16-bit `ImWchar` | works |
| emoji (U+1F300+) | impossible: 16-bit `ImWchar` | works |
| a glyph that is never shown | paid for anyway | not rasterized |

So the merged ranges stay at CJK punctuation, kana and fullwidth forms (about
800 glyphs, which are common in Japanese UI text and cheap), and the ideographs
are rasterized on demand. When the atlas fills, the glyph that did not fit
draws as a tofu box for that frame and the whole cache starts over on the next
one.

## Wide (double-width) glyphs

libghostty reports a cell's width, and a wide cell's glyph is drawn into a box
`2 × cell_w` wide, cached under its own key, so the same character at one and
at two cells are two entries. The cell after a wide one is libghostty's spacer
and carries no graphemes, so nothing overwrites the right half.

## The tofu box

A code point that is in no font — neither the terminal font nor any font of the
chain — draws as a hollow rectangle inset in its cell, with the code point's hex
digits inside it, two to a row (two rows in the BMP, three above it). The digits
appear only at 6 pixels a digit or more, which a world panel or a large font
size reaches and an 8×16 cell does not; below that the box stands alone rather
than becoming a smudge. The box is also what a glyph gets when the atlas is
full for that frame, or when there is no D3D11 device at all (an older shim).

This replaces a mix that used to depend on which of three things failed:
sometimes ImGui's U+FFFD, sometimes a blank cell, sometimes the merged font's
own fallback glyph. One shape now means one thing — "no font here has this" —
and says which code point it was.

## Tests

`tests/test_glyphfb.nelua` (through `tests/run.sh`) covers the decoding, the
`wants` decision on both cimgui exports, lazy reading of the chain, emoji and
wide glyphs over exactly two cells with the next cell untouched, a font added
behind the chain, the tofu box and its digits, the cache, a full atlas and
device changes, against a fake ImGui and a fake D3D11.

The real-ideograph checks need a CJK font, which is too big to ship with the
tests; set `GHOSTTY_TEST_CJK_FONT` to one (for example Dalamud's
`UIRes/NotoSansCJK-Regular.ttc`) and they run too. Nothing here has been
verified in the game itself.

# Fallback fonts

Merged behind Inconsolata into the terminal fonts (`shim/GhosttyDalamud/HostApi.cs`)
for glyphs Inconsolata lacks. Box drawing, block elements, braille and the
powerline separators are drawn as shapes instead (`core/boxdraw.nelua`).

Dalamud's ImGui stores 16-bit code points, so glyphs above U+FFFF (emoji, the
Nerd Font Material Design icons at U+F0000 and up, CJK Extension B) never come
from the merged ImGui font. The core rasterizes those, and any BMP glyph the
merged font lacks, itself with stb_truetype from the same files, in this order:
`SymbolsNerdFontMono-Regular.ttf`, `NotoSansSymbols2-Regular.ttf`,
`NotoEmoji[wght].ttf`, then the host's own CJK font (Dalamud's Noto Sans CJK,
found by the shim and added by `core/app/lifecycle.nelua`; too big to ship
here). A code point no font in that chain has draws as a box with its hex
digits. See `core/glyphfb.nelua` and `docs/GLYPHS.md`.

Each file is read on the first glyph the files before it do not have, never
sooner, so a session with no emoji and no CJK pays for neither.

| File | Source | License |
| --- | --- | --- |
| `SymbolsNerdFontMono-Regular.ttf` | [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) v3.4.0, `NerdFontsSymbolsOnly.zip` | MIT (`LICENSE-SymbolsNerdFont.txt`) |
| `NotoSansSymbols2-Regular.ttf` | [Noto Sans Symbols 2](https://github.com/notofonts/symbols) | SIL OFL 1.1 (`LICENSE-NotoSansSymbols2.txt`) |
| `NotoEmoji[wght].ttf` | [Noto Emoji](https://github.com/google/fonts/tree/main/ofl/notoemoji) 3.002, monochrome, unmodified upstream variable font (`NOTO_EMOJI_URL`/`NOTO_EMOJI_SHA256` in `toolchain.env`) | SIL OFL 1.1 (`LICENSE-NotoEmoji.txt`) |

`NotoEmoji[wght].ttf` is the weight-axis variable font Google Fonts ships; there
is no smaller static build of monochrome Noto Emoji upstream any more, and
stb_truetype rasterizes its default instance (Regular) correctly. Colour emoji
would need a CBDT or COLRv1 font (`NotoColorEmoji.ttf` is 10 MB) and a colour
rasterizer: the fallback atlas holds one coverage channel tinted by the cell's
foreground, so colour emoji are out of scope.

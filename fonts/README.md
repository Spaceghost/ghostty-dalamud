# Fallback fonts

Merged behind Inconsolata into the terminal fonts (`shim/GhosttyDalamud/HostApi.cs`)
for glyphs Inconsolata lacks. Box drawing, block elements, braille and the
powerline separators are drawn as shapes instead (`core/boxdraw.nelua`).

Dalamud's ImGui stores 16-bit code points, so glyphs above U+FFFF (Nerd Font
Material Design icons at U+F0000 and up, for example) never come from the
merged ImGui font. The core rasterizes those, and any BMP glyph the merged font
lacks, itself with stb_truetype from the same files, in this order:
`SymbolsNerdFontMono-Regular.ttf`, `NotoSansSymbols2-Regular.ttf`, then
`NotoEmoji-Regular.ttf` when one is placed here (monochrome
[Noto Emoji](https://github.com/google/fonts/tree/main/ofl/notoemoji), OFL; not
shipped). See `core/glyphfb.nelua`.

| File | Source | License |
| --- | --- | --- |
| `SymbolsNerdFontMono-Regular.ttf` | [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) v3.4.0, `NerdFontsSymbolsOnly.zip` | MIT (`LICENSE-SymbolsNerdFont.txt`) |
| `NotoSansSymbols2-Regular.ttf` | [Noto Sans Symbols 2](https://github.com/notofonts/symbols) | SIL OFL 1.1 (`LICENSE-NotoSansSymbols2.txt`) |

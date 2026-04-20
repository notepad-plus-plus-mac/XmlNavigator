# XML Navigator — macOS port

Tree-view navigator for XML documents in Notepad++. Click any node to jump
to its position in the editor; right-click for more actions. Permissive
hand-rolled tokenizer works on malformed XML the user's still typing.

macOS port of the archived Windows
[XmlNavigator](https://github.com/chcg/XmlNavigator) plugin by Christian Grasser.

## Features

- Floating panel with NSOutlineView tree
- Compact +/- disclosure markers (no native triangles) — same footprint as the
  Search Results Panel's Scintilla fold markers
- Filter text field with all-tokens-must-match semantics (order-independent,
  case-insensitive)
- Attribute values rendered inline as `element [attrValue1] [attrValue2]…`
  for quick visual scanning
- Six-item right-click context menu:
  - Go to Node Start / Node End
  - Go to Content Start / Content End
  - Select Node / Select Content
- Auto-reload on `NPPN_BUFFERACTIVATED`, `NPPN_FILESAVED`, and text changes
- Tolerant of ill-formed XML (no hard parse errors — the tree just shows what
  it can reach)
- Cmd+=, Cmd+-, Cmd+0 to zoom the tree font up, down, and back to the
  default (11 pt)

## Installation

Install via **Plugins → Plugin Admin** in Notepad++, or drop the
`XmlNavigator` folder from the release zip into `~/.notepad++/plugins/`.

## Usage

`Plugins → XML Navigator → Show XML Navigator` opens the panel. Click any
row to jump the editor caret to that node. The filter box narrows the tree
by display name (including attribute values rendered in the label).

## Building from source

```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
cp XmlNavigator.dylib ~/.notepad++/plugins/XmlNavigator/
```

The CMakeLists defaults to `Release` with `-O3 -DNDEBUG` and universal
binary (`arm64;x86_64`) if `CMAKE_BUILD_TYPE` and `CMAKE_OSX_ARCHITECTURES`
aren't overridden. ARC is enabled via `-fobjc-arc`.

## License

MIT — see [LICENSE](LICENSE). The original Windows plugin did not ship an
explicit license.

## Links

- Original Windows plugin (archived): https://github.com/chcg/XmlNavigator

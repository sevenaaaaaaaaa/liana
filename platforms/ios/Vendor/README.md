# Bundled mobile input data

Sources are pinned in each `SOURCE.json`, with SHA-256 hashes checked during the mobile index build. No build-time network download is needed.

- [HanziLookupJS](https://github.com/gugray/HanziLookupJS), revision `b21124f771ddd91f131e62aa478bc188f6ec78d3`: unmodified `dist/hanzilookup.min.js` (GPL-3.0) and `dist/mmah.json` (Arphic Public License). Full license files and the corresponding unminified library source / build recipe are included in `Source/`. The Swift JavaScriptCore adapter initializes the local model directly without the original XMLHttpRequest loader. Model data derives from Make Me a Hanzi; attribution and terms are in `LICENSE-APL`.
- [Rime Wubi](https://github.com/rime/rime-wubi), revision `152a0d3f3efe40cae216d1e3b338242446848d07`: unmodified `wubi86.dict.yaml`, `AUTHORS`, and `LICENSE` (LGPL-3.0). `LICENSE-Wubi.txt` is an identical copy named uniquely for the flattened iOS resource bundle. The build converts the dictionary into an indexed SQLite table; the original editable source is shipped in this repository.

The keyboard bundles the recognizer, offline model, SQLite index and complete license texts. Liana's surrounding code remains AGPL-3.0-only. See repository root LICENSE.

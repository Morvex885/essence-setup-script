# Вендоренные файлы веб-панели

Файлы скачаны без изменений (HTTP 200). Содержимое не правится; обновление — новой загрузкой с записью версии и SHA-256 здесь. Запасной источник той же версии — `https://cdn.jsdelivr.net/npm/<пакет>@<версия>/<путь>`.

| Файл | Пакет | Версия | Источник | SHA-256 |
|---|---|---|---|---|
| `preact-htm.js` | `htm` (Preact + htm, standalone) | 3.1.1 | `https://unpkg.com/htm@3.1.1/preact/standalone.module.js` | `72284e8e9079c87817145df1110f74e8a2aa040b2fc384922e18dfcb46fc1fd7` |
| `xterm.js` | `@xterm/xterm` | 5.5.0 | `https://unpkg.com/@xterm/xterm@5.5.0/lib/xterm.js` | `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495` |
| `xterm.css` | `@xterm/xterm` | 5.5.0 | `https://unpkg.com/@xterm/xterm@5.5.0/css/xterm.css` | `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6` |
| `xterm-addon-fit.js` | `@xterm/addon-fit` | 0.10.0 | `https://unpkg.com/@xterm/addon-fit@0.10.0/lib/addon-fit.js` | `bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089` |
| `qrcode.js` | `qrcode-generator` | 1.4.4 | `https://unpkg.com/qrcode-generator@1.4.4/qrcode.js` | `18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780` |
| `daisyui.css` | `daisyui` | 5.8.0 | `https://cdn.jsdelivr.net/npm/daisyui@5.8.0/daisyui.css` | `8cd7c14fc3aebb0fdfdcb03f7dc8dc198d868cefbb2499c6612d63508c8becaf` |
| `ace/ace.js` | `ace-builds` | 1.45.2 | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/src-min-noconflict/ace.js` | `6430923a29a3d30f94eb321700a56ec12cb8060270831632087d166bbac7aca9` |
| `ace/mode-yaml.js` | `ace-builds` | 1.45.2 | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/src-min-noconflict/mode-yaml.js` | `24faa242ac5085656ff0b9fe283edc8d8565c2ad84f5a824b5868eb5a7ca5cb3` |
| `ace/ext-searchbox.js` | `ace-builds` | 1.45.2 | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/src-min-noconflict/ext-searchbox.js` | `427ec52caf01e02536f8429adeb2baee82cdd122f2c25cf01663959734019773` |
| `ace/theme-github_light_default.js` | `ace-builds` | 1.45.2 | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/src-min-noconflict/theme-github_light_default.js` | `e3efc95cc037b3451dfe554741c14074a4b2ba8c8c618980f6af0686d190ae29` |
| `ace/theme-github_dark.js` | `ace-builds` | 1.45.2 | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/src-min-noconflict/theme-github_dark.js` | `e4eb84614dd42fa98f70f017e0353ac9df68e09f3a28ff817db06b58db4c6ab7` |
| `../js/icons.js` (внутренние элементы SVG) | `lucide-static` | 1.72.0 | `https://cdn.jsdelivr.net/npm/lucide-static@1.72.0/icons/` (`<имя>.svg`) | — (содержимое `<svg>` каждой иконки скопировано без изменений в `assets/js/icons.js`) |

Глобальные имена классических скриптов: `Terminal` (`xterm.js`), `FitAddon.FitAddon` (`xterm-addon-fit.js`), `qrcode` (`qrcode.js`). `preact-htm.js` — ES-модуль (`html`, `render`, `useState`, `useEffect`, `useRef`, …).

## Лицензии

Тексты лицензий лежат рядом и вшиваются в бинарник вместе с `assets` (`include_dir!`); слушатель их не отдаёт: файлы без расширения не входят в список типов содержимого.

| Файл | Пакет | Лицензия | Источник | SHA-256 |
|---|---|---|---|---|
| `LICENSE-htm` | `htm` 3.1.1 (`preact-htm.js`) | Apache-2.0 | `https://raw.githubusercontent.com/developit/htm/3.1.1/LICENSE` | `740725f7252e750af735d0028cc534970772f513331e9f68150fede8fb3ce00f` |
| `LICENSE-preact` | `preact` 10.x, вшитый в сборку `htm` 3.1.1 (`preact-htm.js`) | MIT | `https://raw.githubusercontent.com/preactjs/preact/10.2.0/LICENSE` | `1fe6958409c8c257a70c587a18b6f7f412b179b456630790d30b2ec9a8e4b7d4` |
| `LICENSE-xterm` | `@xterm/xterm` 5.5.0, `@xterm/addon-fit` 0.10.0 (`xterm.js`, `xterm.css`, `xterm-addon-fit.js`) | MIT | `https://raw.githubusercontent.com/xtermjs/xterm.js/5.5.0/LICENSE` | `b569f629d00f2626a8100df2a1798210535621e42164dfd426a6fe5aac7b0ccd` |
| `LICENSE-daisyui` | `daisyui` 5.8.0 (`daisyui.css`) | MIT | `https://cdn.jsdelivr.net/npm/daisyui@5.8.0/LICENSE` | `8709e3ac65c84637c422dc8082b893d9997fce093751c77b2f1983bf29dbf9ea` |
| `LICENSE-ace` | `ace-builds` 1.45.2 (`ace/*.js`) | BSD-3-Clause | `https://cdn.jsdelivr.net/npm/ace-builds@1.45.2/LICENSE` | `850f545c5254e8c08204edb2a6d50bbb72727c38a82982c17a84bebf6064cdf8` |
| `LICENSE-lucide` | `lucide-static` 1.72.0 (иконки в `assets/js/icons.js`) | ISC | `https://cdn.jsdelivr.net/npm/lucide-static@1.72.0/LICENSE` | `b495047bd93a9b06913511076f504daba17d5bbeb3e0650f3bb53a4220329c57` |

`qrcode.js` (MIT) несёт уведомление об авторских правах в заголовке файла.

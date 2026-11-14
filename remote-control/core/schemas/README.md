# JSON-схема конфигурации Mihomo

Файл `meta-json-schema.json` скачан без изменений (HTTP 200). Обновление — новой загрузкой с записью версии и SHA-256 здесь.

| Файл | Пакет | Версия | Источник | SHA-256 |
|---|---|---|---|---|
| `meta-json-schema.json` | `meta-json-schema` | v1.19.33 | `https://github.com/dongchengjie/meta-json-schema/releases/download/v1.19.33/meta-json-schema.json` | `6bd95d7aca338ce80f6b4adf931190b970d1acba35bb0f68d34a528aef28da66` |

Лицензия: MIT, `https://github.com/dongchengjie/meta-json-schema/blob/main/LICENSE`. Текст — `LICENSE-meta-json-schema` (скачан с `https://raw.githubusercontent.com/dongchengjie/meta-json-schema/main/LICENSE`, SHA-256 `52e858ecaecc918d1b2654b7ef69cbee6fbc9a3d84111c1e2fcff94a14250a7f`).

## Исправления при загрузке

Файл не правится (SHA-256 выше); `core/src/clients/template_check.rs::patch` исправляет разобранную схему перед компиляцией валидатора. Если у новой версии нужного места нет, схема не загружается (`template check` — `failed`): исправления пересматриваются при обновлении.

1. `definitions/proxies/definitions/shadowsocksr/definitions/compatible/{string,integer,number,boolean}/anyOf/1` — ветка с `pattern` без `type` принимает любой не-строковый узел (объект или список в скалярном поле). Ей задаётся тип второй формы: `number` для `string`, `string` для остальных.
2. `definitions/proxy-groups/definitions/load-balance/definitions/groupbase/allOf/0` — `required: [name, type]` рядом с `$ref` в draft-07 не действует; `$ref` переносится во вложенный `allOf`.
3. `definitions/listeners/items/anyOf/*/allOf/0` — ветка различает вид по `properties.type.const`, но `type` не требует: элемент без `type` (mihomo: `missing type`) проходит как `socks`. Ей добавляется `required: [type]`.

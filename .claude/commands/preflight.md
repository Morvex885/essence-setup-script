---
description: Финальный чек перед сдачей — bash -n на изменённых .sh + релевантные BATS
---

Прогони чек-лист из CLAUDE.md «Перед сдачей задачи»:

1. **`bash -n` на каждом изменённом `.sh`.** Возьми список из `git diff --name-only` + `git diff --cached --name-only` + `git ls-files --others --exclude-standard`, отфильтруй по `*.sh`. По каждому — `bash -n <file>`. Любая ошибка синтаксиса = блокер, остановись и покажи.

2. **Релевантные BATS-тесты.** Определи затронутые модули и подбери покрывающие их тесты:
   - правил `common/common.sh` — `bash tests/run_tests.sh --unit` целиком (база)
   - правил `common/<file>.sh` — найти `tests/unit/*.bats`, где `source_module` или `source_common` касается этого файла
   - правил `setup-essence/modules/<X>.sh` или `remote-control/modules/<X>.sh` — найти тесты, имя которых перекликается с модулем (`node_*.bats` для `nodes.sh`, `subscription_*.bats` для `subscription.sh`, и т.п.)
   - если изменены парсеры/энкодеры — обязательно прогнать соответствующий `tests/fuzz/fuzz_*.bats`
   - если правил `common/` или `remote-control/modules/` — `bash tests/run_tests.sh --all`

3. **Отчёт.** Короткий summary: список проверенных `.sh`, список прогнанных `.bats`, что упало (если упало). Если всё зелёное — одна строка «preflight: OK».

Падающий тест — баг в коде, а не в тесте. Не подгонять ожидания теста под код.

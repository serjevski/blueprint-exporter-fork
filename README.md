Русская версия ниже.


# Blueprint Exporter
The idea for the mod and most of the implementation belong to other people who published this mod on the Factorio mod portal. (https://mods.factorio.com/mod/blueprint-exporter)

Factorio 2.1 mod that exports your entire blueprint library to files, so you can keep it in git.

## Usage

1. Install the mod and click the **Export blueprint library** button on the shortcut bar.
2. The export lands in `script-output/blueprint-exporter/`: books become directories. Each blueprint/planner produces two files — `.txt` with the exchange string, and `.json` with the full blueprint data (keys alphabetically sorted, case kept). Both "My blueprints" and "Game blueprints" are included. Large libraries are processed a few records per tick, so the game stays responsive.
3. (Optional) Run `publish.ps1` to copy the mod into a zip archive ready for
   the Factorio mods folder or the mod portal.

## What the export looks like

```text
blueprint-exporter/
  manifest.json             everything written, with a format version
  p/                        "My blueprints"  (g/ = "Game blueprints")
    001_Roboport.txt        the exchange string, what the game imports
    001_Roboport.json       the same payload, decoded and pretty printed
    007_Circuits/
      _book.json            the book's real name, see below
      001_All my Circuits.txt
      001_All my Circuits.json
  tools/                    converters, rewritten on every export
```

File and directory names are `<index>_<label>`. The index keeps two blueprints with
the same name apart; markup (`[item=steel-plate]`, `[/color]`, ...) is stripped,
because it would otherwise be half of every path. The label the game actually shows
is kept in the export instead:

- `_export.label` in a blueprint's `.json`, and `_export.book_path` with the
  original names of the books it sits in, outermost first;
- `_book.json` in a book's directory — a book has no file of its own, so this is the
  only place its name survives. An empty book gets one too.

A name keeps the case you typed: `Belt` and `belt` are two different files.

Keys in `.json` keep the order Factorio wrote them in, so a re-export does not
shuffle every line of a hand-edited blueprint. Their case is kept: mod data under
`metadata` is case-sensitive, and a key renamed on the way out could not be renamed
back. **The `.txt` stays the authoritative copy** and the `.json` is the readable one.

Paths are kept under 140 UTF-16 units so Windows does not refuse them; a directory
shares what is left with everything under it, so deep book nesting cannot overflow
it.

## Turning an edited .json back into a blueprint

Both converters are written into `tools/` at the end of every export — they travel
inside the mod, because Factorio's Lua cannot read a file at runtime. They rebuild an
importable string from a `.json`; paste the result into the in-game blueprint string
box.

```powershell
# PowerShell 5.1+, one file to the clipboard
./tools/json-to-string.ps1 ./001_Roboport.json | Set-Clipboard

# a whole tree, mirrored into a directory of .txt
./tools/json-to-string.ps1 ./blueprint-exporter -Out ./rebuilt
```

```bash
# bash, needs gzip, base64 and (for validation) python3
./tools/json-to-string.sh 001_Roboport.json | xclip -selection clipboard
./tools/json-to-string.sh blueprint-exporter rebuilt
```

Both skip `_book.json` and `manifest.json`, drop `_export`, and never re-serialize
the payload — the bytes of the file are what get compressed, so every number survives
exactly. `-Raw` / `--raw` prints plain JSON instead of the compressed string, which
Factorio 2.0 and newer accept for import as well.

## Testing

```text
node .dev-test/run.js                 Lua suite under fengari, no game needed
node .dev-test/check_converters.js    builds a fixture with the real export code and
                                      drives both converters through it
node .dev-test/check_real_export.js <export dir>
                                      re-derives every name from a real export
```

`node .dev-test/embed_tools.js` refreshes the copy of the converters that the mod
ships; run it after editing either script, and the suite fails if you forget.

## Build

`publish.ps1` creates `publish/blueprint-exporter_<version>.zip` ready for the
mod portal. It zips the mod root and drops the archive into
`%APPDATA%\Factorio\mods\`.

---

# Blueprint Exporter (на русском)
Идея мода и большая часть реализации принадлежит другим людям, опубликовавшим этот мод на портале модов Факторио (https://mods.factorio.com/mod/blueprint-exporter)

Мод для Factorio 2.1, который выгружает всю библиотеку чертежей в файлы, чтобы
её можно было хранить в git.

## Использование

1. Установите мод и нажмите кнопку **Export blueprint library** на панели быстрых действий.
2. Экспорт попадает в `script-output/blueprint-exporter/`: книги становятся каталогами.
   Каждый чертёж или планировщик даёт два файла — `.txt` со строкой обмена и `.json`
   с полными данными чертежа (порядок ключей сохранён, регистр тоже). Забираются и
   «Мои чертежи», и «Чертежи игры». Большие библиотеки обрабатываются по несколько
   записей за тик, чтобы игра не подвисала.
3. (Необязательно) Запустите `publish.ps1`, чтобы собрать мод в zip-архив, готовый
   для папки модов Factorio или портала модов.

## Как выглядит экспорт

```text
blueprint-exporter/
  manifest.json             всё записанное, с версией формата
  p/                        «Мои чертежи»  (g/ = «Чертежи игры»)
    001_Roboport.txt        строка обмена, именно её импортирует игра
    001_Roboport.json       те же данные, распакованные и отформатированные
    007_Circuits/
      _book.json            настоящее имя книги, см. ниже
      001_All my Circuits.txt
      001_All my Circuits.json
  tools/                    конвертеры, перезаписываются при каждом экспорте
```

Файлы и каталоги называются как `<индекс>_<метка>`. Индекс разделяет два чертежа
с одинаковым именем; разметка (`[item=steel-plate]`, `[/color]`, ...) вырезается,
иначе она занимала бы половину каждого пути. Вместо неё настоящая метка хранится
в самом экспорте:

- `_export.label` в `.json` чертежа и `_export.book_path` с исходными именами книг,
  в которых он лежит, от внешней к внутренней;
- `_book.json` в каталоге книги — у книги нет собственного файла, так что это
  единственное место, где её имя остаётся. Пустая книга получает такой файл тоже.

Имя сохраняет набранный вами регистр: `Belt` и `belt` — два разных файла.

Ключи в `.json` идут в том порядке, в котором их записал Factorio, поэтому повторный
экспорт не перемешивает каждую строку чертежа, который правили вручную. Регистр тоже
сохраняется: данные модов в `metadata` чувствительны к регистру, и ключ, переименованный
на выходе, нельзя было бы переименовать обратно. **`.txt` остаётся основной копией**,
а `.json` — читаемой.

Пути удерживаются в пределах 140 единиц UTF-16, чтобы Windows не отказывалась их
создавать; каталог делит остаток бюджета со всем, что под ним, поэтому глубокая
вложенность книг не может выйти за лимит.

## Как вернуть отредактированный .json в чертёж

Оба конвертера записываются в `tools/` в конце каждого экспорта — они едут внутри
мода, потому что Lua Factorio не умеет читать файлы во время игры. Они собирают
импортируемую строку из `.json`; результат нужно вставить в игровое поле строки чертежа.

```powershell
# PowerShell 5.1+, один файл в буфер обмена
./tools/json-to-string.ps1 ./001_Roboport.json | Set-Clipboard

# всё дерево, результат раскладывается по каталогу .txt
./tools/json-to-string.ps1 ./blueprint-exporter -Out ./rebuilt
```

```bash
# bash, нужны gzip, base64 и (для проверки) python3
./tools/json-to-string.sh 001_Roboport.json | xclip -selection clipboard
./tools/json-to-string.sh blueprint-exporter rebuilt
```

Оба пропускают `_book.json` и `manifest.json`, убирают `_export` и никогда не
переписывают данные заново — сжимаются ровно байты файла, поэтому каждое число
сохраняется без изменений. `-Raw` / `--raw` печатает обычный JSON вместо сжатой
строки — Factorio 2.0 и новее принимает для импорта и такой вид.

## Тесты

```text
node .dev-test/run.js                 набор Lua-тестов на fengari, игра не нужна
node .dev-test/check_converters.js    строит фикстуру настоящим кодом экспорта и
                                      прогоняет через неё оба конвертера
node .dev-test/check_real_export.js <каталог экспорта>
                                      заново выводит каждое имя из реального экспорта
```

`node .dev-test/embed_tools.js` обновляет копию конвертеров, которую мод носит с собой;
запускайте её после правки любого из скриптов, иначе тесты не пройдут.

## Сборка

`publish.ps1` создаёт `publish/blueprint-exporter_<version>.zip`, готовый для портала
модов. Он архивирует корень мода и кладёт архив в `%APPDATA%\Factorio\mods\`.

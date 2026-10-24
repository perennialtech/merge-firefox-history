# Contributing

## Requirements

- Bash 4.0 or newer
- SQLite 3.24.0 or newer
- Python 3.8 or newer (standard library only, for the test suite)
- [shfmt](https://github.com/mvdan/sh) 3.14.1
- Node.js 20 or newer with [pnpm](https://pnpm.io) 12.10.1

## Setup

```shell
pnpm install
```

## Formatting

```shell
pnpm run format        # rewrite shell, Markdown, YAML and JSON files
pnpm run format:check  # check without writing (used by CI)
```

Shell formatting is configured in `.editorconfig`; Markdown, YAML and JSON
formatting is configured in `.prettierrc.json`.

## Tests

The integration tests create temporary Places-shaped databases with Python's
standard `sqlite3` module and run the real script against them. They cover
merge invariants, hard links, WAL snapshots, failure recovery, output mode,
older schemas, and URL-hash reference vectors.

```shell
python3 -m unittest discover -s tests -v
```

To test against genuine Firefox-created databases, install Firefox,
[geckodriver](https://github.com/mozilla/geckodriver) and
[Selenium](https://www.selenium.dev/documentation/webdriver/). Then run:

```shell
MFFH_REAL_FIREFOX=1 python3 -m unittest discover -s tests -p test_real_firefox.py -v
```

The test opens only local HTTP pages in two temporary Firefox profiles. It
merges their actual `places.sqlite` databases, checks the results and repeat
imports, then deletes both profiles. No personal browser data is used.

## Checks

CI runs formatting, shell syntax, the synthetic integration tests and a
separate real-Firefox integration test on every push and pull request.

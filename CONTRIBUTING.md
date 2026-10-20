# Contributing

## Requirements

- Bash 4.0 or newer
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

## Checks

CI runs `pnpm run format:check` and `bash -n merge-firefox-history.sh` on every
push and pull request.

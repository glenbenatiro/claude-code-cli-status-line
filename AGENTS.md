# AGENTS.md

A boxed status line for Claude Code CLI. Claude Code pipes session JSON to `statusline.sh` on stdin, and the script prints the colored table on stdout. The README is the user-facing reference for every cell, color and file.

## Files

- `statusline.sh`: the whole status line. Single bash script, needs only `jq`.
- `preview.sh`: renders the script against every payload in `fixtures/`, using temporary state so it never touches real files.
- `test.sh`: runs the script as several sessions in turn and checks how they share the rate limits and that bad input can't break it, also with temporary state.
- `fixtures/*.json`: sample payloads (`real-session`, `full`, `early`, `windows`).
- `README.md`: user docs. Keep its cell tables, colors and file lists in step with the script.

## Performance rules

The script runs from scratch every second for every open session, so starting processes is the main cost.

- Parse all fields in the one `jq` call at the top. Do not add a second `jq`.
- Helpers return values in `REPLY` (or a named variable), not by printing into `$(...)`, which forks a subshell.
- Do not call external programs (`date`, `sed`, `awk`, `git`, and so on) on every refresh. Use bash builtins. Rare fallbacks are fine.
- Only write state files when their contents change.

## Structure rules

- The script body runs inside `main`, so bash reads all of it before running any of it and replacing the file mid-run is safe. `shopt -s extglob` and `umask 077` stay above `main`: extglob must be on before the function is parsed.
- `statusline-rate-limits.json` is shared by every session on the machine, so its format is a contract between versions of the script. Keep the keys; bump `version` for an incompatible change. A script never writes over a file with a newer `version`.
- Only a fresh session (one that just heard from the API) writes the shared file. Don't add rules that compare timestamps or let idle sessions write; README "Shared rate limits" explains why.
- Treat the shared file as untrusted input: validate every value before using it in arithmetic or writing it back.

## Portability rules

It must work on Linux, macOS (Homebrew bash 4.2+) and native Windows (Git Bash, run by Claude Code from PowerShell).

- Paths may be Windows paths like `C:\Users\me\project`. Never assume `/` separators, and make sure any loop that walks up a path always ends. Assuming `/` once made the script hang forever on Windows.
- Never assume a UTF-8 locale. Column widths use `${#var}`, which counts bytes without one, and the borders go jagged. The script sets `LC_ALL=C.UTF-8` near the top when needed; keep that.
- Keep `.sh` files on LF line endings (see `.gitattributes`).

## Checking a change

1. `./preview.sh` and look at every fixture, including `windows`.
2. Check the borders line up, with no locale set:
   `unset LANG LC_ALL LC_CTYPE; PLAIN=1 ./preview.sh full | LC_ALL=C.UTF-8 grep '^[│╭├╰]' | LC_ALL=C.UTF-8 awk '{print length}' | sort -u`
   It must print a single number. The locale is set only on `grep` and `awk`, so that the script itself still runs without one.
3. `./test.sh` must print `all passed`. If you change how the rate limits are shared, add a step for the new case.
4. If you add a field or a new kind of input, add or update a fixture for it.

## Commits and PRs

- Conventional prefixes: `feat:`, `fix:`, `perf:`, `docs:`.
- Changes go through a PR, not straight to `main`.
- Do not hard-wrap commit messages or PR descriptions.

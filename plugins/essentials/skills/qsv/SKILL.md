---
name: qsv
description: >
  Inspect, clean, filter, sort, dedup, join, validate and convert CSV/TSV files with the `qsv` CLI
  (dathere, 23.x). Use for any CSV job that is not a SQL query, for schema inference and validation,
  and for streaming or external-sort work on inputs q cannot hold. SQL stays with `essentials:q-sql`.
when_to_use: >
  Load BEFORE running any `qsv` command, or when the task is "clean / profile / dedup / join /
  validate / convert this CSV" and qsv is on PATH. Trigger on: qsv, sniff, stats, frequency,
  dedup, safenames, validate csv, csv to sqlite, csv to xlsx, xlsx to csv, big csv.
---

# qsv

> **Purpose**: the CSV toolkit beside `q-sql`; check the build's command list first, then pick from the matrix.

## Build check

`qsv --list` names the commands this build has. The Homebrew build (features apply, fetch, foreach, geocode,
lens, luau, to) lacks `sqlp`, `joinp` and `pivotp`, so SQL, GROUP BY, non-equi and as-of joins go to
`q -H -d , -O '...'` (skill `essentials:q-sql`). A Polars build from the GitHub release zip adds them; worth
a benchmark only when a measured q run is too slow, such as an as-of join over a large payment export.

## Inspection

```bash
qsv sniff file.csv                      # delimiter, header row, preamble rows, quote char, utf8
qsv headers file.csv                    # 1-based column list
qsv stats file.csv | qsv select field,type,nullcount     # streaming; add --cardinality only when needed
qsv slice --len 5 file.csv | qsv table  # aligned preview
qsv frequency -s col file.csv           # value distribution, or <ALL_UNIQUE>
```

`stats` types are inference and leave the input untouched; `select`, `search`, `sort` copy cells as text
(`00123` stays `00123`). Typed conversions do coerce: `tojsonl` turned `+380` into `380.0`. Check the output
of `tojsonl` and `to` on identifier columns before trusting it.

## Command matrix

| Job | Command | Note |
| --- | --- | --- |
| pick columns | `select name,age` / `select 1-3` / `select '!id'` / `select '/^price/'` | 1-based; regex quoted |
| filter rows | `search -s col 'regex'` | `-s` scopes the column, else whole row |
| sort | `sort -s col` (`-N` numeric, `-R` reverse) | whole file in memory |
| sort, huge | `extsort -s col file.csv` after `qsv index file.csv` | without `-s` it sorts raw lines, no `-N` |
| dedup | `dedup` | sorts the output; removed count on stderr; `--sorted` exits 1 on unsorted input |
| join | `join --left key a.csv key b.csv` | hash join, both key columns in output |
| concat | `cat rows a.csv b.csv` | same column order; `cat rowskey` for differing |
| header hygiene | `safenames` | `First Name,Total $` → `first_name,total__` |
| per-row expr | `luau map c 'a + b'` | Lua, new column `c` |
| infer schema | `schema file.csv` | writes `file.csv.schema.json` with enums and min/max from the data |
| validate | `validate file.csv schema.json` | "All N records valid.", or exit 1 plus three side files |
| convert out | `to sqlite out.db file.csv` / `to xlsx` / `tojsonl` | sqlite table = file stem (`people`) |
| convert in | `excel --sheet S file.xlsx` | Excel/ODS to CSV on stdout |

A generated schema encodes the sample: the enum lists every value seen and the bounds are the observed
min/max. Edit it into the intended contract before validating future exports with it.

## Input rules

| Rule | Detail |
| --- | --- |
| delimiter | comma by default; `.tsv` and `.ssv` switch the INPUT by extension, output is still comma |
| header | assumed; `--no-headers` for none, then columns are `1..N` |
| ragged rows | hard error "found record with 3 fields, but the previous record has 2" |
| `fixlengths --length N` | pads or truncates every row to N, exit 0; inspect delimiter and quoting first |
| stdin | `-` or empty for most commands; `fixlengths` and `extsort` need a file path |
| space-aligned output (`ps`, `ls -l`) | not CSV; q handles it, qsv does not |

## Side files

Regenerable caches beside the data: `file.csv.idx` from `index`; `file.stats.csv` and possibly
`.stats.csv.json` and `.stats.csv.data.jsonl` from `stats`, `schema` and `tojsonl`. `qsv clean` removes them
(dry run by default). Deliberate outputs stay: `file.csv.schema.json`, and from a failed `validate`
`file.csv.valid`, `file.csv.invalid`, `file.csv.validation-errors.tsv`.

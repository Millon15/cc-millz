---
name: q-sql
description: >
  Run SQL queries on CSV, TSV, delimited files, command output or sqlite files with harelba's
  `q` CLI (3.x). Use for filtering, grouping, aggregating or joining these sources with SQL, and
  for troubleshooting a `q` command that returns wrong columns, wrong types or an error.
when_to_use: >
  Load BEFORE running or writing any `q "select ..."` command, or when the task is "SQL over a
  CSV/TSV/log/command output" and q is on PATH. Trigger on: q, harelba, text as data,
  sql on csv, query this csv, group by this file, join two csv files, .qsql, .qrc.
---

# q-sql

> **Purpose**: the defaults of `q` are wrong for CSV; set the flags first, then write SQLite SQL.

## Every invocation

```bash
q -H -d , -O 'select ... from file.csv'        # CSV with a header row
q -H -t -O 'select ... from file.tsv'          # TSV
some-cmd | q -H -O 'select ... from -'         # command output, space-delimited, header line first
q -A -H -d , 'select * from file.csv'          # schema or types unknown: prints names and types, exits
```

| Flag | Default without it | What it does |
| --- | --- | --- |
| `-d ,` / `-t` / `-p` | delimiter is SPACE | field delimiter comma / tab / pipe |
| `-H` | columns are `c1..cN`; a header row becomes data and can force text inference | first row names the columns |
| `-O` | no header on output | output a header line from the SELECT aliases |
| `-D x` / `-T` / `-P` | output delimiter = input delimiter | output delimiter x / tab / pipe |
| `-A` | | print detected schema and exit |
| `--as-text` | `00123` → `123`, `+380` → `380` | keep every column text; `cast(col as text)` cannot undo the loss |
| `-k` | leading whitespace stripped, even with `--as-text` | keep leading whitespace |
| `-m strict -c N` | relaxed: ragged rows padded or spilled into extra columns, exit 0 | reject width mismatch, exit 2 |
| `-b` | | pad columns for reading; slow on large files |
| `-e enc` / `-E enc` | UTF-8 in, terminal out | input / output encoding |

Identifier-like columns (zips, phones, ids) need `--as-text`; cast the numeric operands in SQL instead.

## Query dialect

SQLite, with the bundled runtime's feature set (window functions run on 3.1.6). Put the SQL in single
quotes and column names with spaces or symbols in double quotes: `q -H -d , 'select "First Name" from f.csv'`.
Backticks also work in q, but inside a double-quoted shell string they run as command substitution. A long
or awkward query goes in a file: `q -H -d , -q query.sql`. Extra functions beyond SQLite (`regexp`,
`regexp_extract`, `percentile`, `stddev_pop`, `stddev_sample`, `sha`, `md5`): signatures from `q -L`.

## Sources

| Source | Table name in FROM |
| --- | --- |
| delimited file | `./path/file.csv` (relative to cwd) |
| stdin | `-` |
| gzipped file | `file.csv.gz`, auto; gzipped stdin needs `-z` |
| glob | `logs/*.csv`, ONLY when every file has an identical header, else "Bad header row" |
| sqlite table | `db.sqlite:::table`, or `db.sqlite` alone when it holds one table |
| a join | `from a.csv a left join b.csv b on a.id = b.id`, every file gets the same `-d`/`-H` |

Command output whose first line is not a header (`ls -l` begins with `total N`) fails with "Header line is
expected but missing"; drop that line with `tail -n +2` before the pipe.

## Cache and persistence

| Flag | Effect | Side effect |
| --- | --- | --- |
| `-C readwrite` | builds `<file>.qsql` beside the file; later runs read it | new file in the tree; never commit |
| `-C read` | uses an existing `.qsql`, never writes one | none |
| `-S out.sqlite` | saves the INPUT tables and exits; SELECT printed, not run | table `people_dot_csv` for `people.csv` |

Persistent flag defaults live in `~/.qrc`; `q --dump-defaults` prints the template.

## Other tools

q is for joins across a few delimited files, SQL over `ps` / `df` / log output through `-`, and a sqlite
file queried without opening a shell. Parquet, JSON, or inputs measured in gigabytes go to DuckDB; SQL-free
transforms (dedup, frequency tables, reshaping) go to qsv or mlr.

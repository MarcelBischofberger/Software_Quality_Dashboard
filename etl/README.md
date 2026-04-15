# ETL — DCOLLECT Volumes Collector

> Collects DASD volume metrics from z/OS via **IDCAMS DCOLLECT** and writes a
> CSV file ready to be loaded into the `VOLUMES` table with the **DB2 LOAD** utility.

Two versions are provided — choose based on your environment:

| Version | Script | Runs on | Auth required |
|---------|--------|---------|--------------|
| **ZOAU** (preferred) | `dcollect_volumes_zoau.py` | z/OS (Python for z/OS + ZOAU) | z/OS TSO user |
| REST/z/OSMF | `dcollect_volumes.py` | Any workstation | z/OS user + z/OSMF port |

---

## `dcollect_volumes_zoau.py` — ZOAU Version

Runs **directly on z/OS**.  Uses Z Open Automation Utilities:

| ZOAU interface | Purpose |
|----------------|---------|
| `mvscmd.execute(pgm='IDCAMS', dds=[...])` | Run IDCAMS DCOLLECT |
| `zoau_io.zopen("//'DSN'", 'rb')` | Read binary DCOLLECT output record-by-record |
| `zoau_io.zopen("//'DSN'", 'w')` | Write CSV to a z/OS sequential dataset |
| `datasets.create()` / `datasets.delete()` | Temp dataset lifecycle |

### Architecture

```
volumes.txt / --volumes args
       │
       ▼
Build IDCAMS SYSIN control cards
Write to temp USS file (/tmp/...)
       │
       ▼
mvscmd.execute(pgm='IDCAMS',
  dds=[
    DDStatement('DCOUT',    DatasetDefinition(work_dsn, NEW, VB)),
    DDStatement('SYSIN',    FileDefinition('/tmp/sysin.file')),
    DDStatement('SYSPRINT', FileDefinition('/tmp/sysprint.file')),
  ])
       │
       ▼
zopen("//'HLQ.DCVOL.XXXXXXXX'", 'rb')
  → iterate records (RDW stripped by ZOAU)
  → parse DCDVOL DSECT fields per record
       │
       ▼
Write CSV → USS file  or  z/OS dataset via zopen('w')
       │
       ▼
datasets.delete(work_dsn)   ← always cleaned up
```

### Prerequisites

- Python for z/OS with `zoautil_py` package installed
- `ZOAU_HLQ` environment variable set  **or** pass `--hlq`
- Your TSO user must be able to allocate/delete datasets under the HLQ

### Usage — ZOAU version

```bash
# Write output to a USS file (default)
python dcollect_volumes_zoau.py \
    --volumes SYS001 SYS002 USR001 \
    --env-id 1 \
    --hlq SYSADM \
    --output /u/sysadm/volumes.csv

# Write output directly to a z/OS sequential dataset
python dcollect_volumes_zoau.py \
    --volume-file volumes.txt \
    --env-id 1 \
    --hlq SYSADM \
    --output-dsn SYSADM.SQLDASH.VOLUMES.CSV

# Use environment variable for HLQ
export ZOAU_HLQ=SYSADM
python dcollect_volumes_zoau.py --volumes SYS001 --env-id 1
```

### DB2 LOAD commands

**From USS file:**
```sql
LOAD FROM /u/sysadm/volumes.csv OF DEL
  MODIFIED BY COLDEL,
  INSERT INTO VOLUMES
  (ENV_ID, VOLSER, DEVICE_TYPE, SMS_MANAGED, STORAGE_GROUP,
   TOTAL_CAPACITY_MB, FREE_SPACE_MB, FREE_SPACE_TRK, FREE_SPACE_CYL,
   FREE_EXTENTS, LARGEST_FREE_EXT_CYL, LARGEST_FREE_EXT_TRK,
   PERCENT_FREE, FRAGMENTATION_INDEX)
  NONRECOVERABLE;
```

**From z/OS dataset:**
```sql
LOAD FROM SYSADM.SQLDASH.VOLUMES.CSV OF DEL
  MODIFIED BY COLDEL,
  INSERT INTO VOLUMES (...)
  NONRECOVERABLE;
```

---

## `dcollect_volumes.py` — z/OSMF REST Version

Runs on **any workstation** (Windows, Linux, Mac).  No ZOAU required.
Submits JCL via z/OSMF REST API, polls for job completion, downloads the
binary dataset, and writes a local CSV file.

See the full documentation below.

---

## Files

| File | Purpose |
|------|---------|
| `dcollect_volumes.py` | Main ETL script |
| `volumes.txt` | Sample volume serial list |

## Prerequisites

- Python 3.11+  (no third-party packages required — uses stdlib only)
- z/OSMF active on the target z/OS system (port 443 by default)
- Your user ID must have:
  - `READ` access to the DCOLLECT facility (`IRR.ZOSMF` or equivalent)
  - Permission to allocate temporary datasets under your HLQ
  - JES job submission authority

## Usage

### Pass volumes on the command line

```bash
python dcollect_volumes.py \
    --volumes SYS001 SYS002 USR001 \
    --env-id 1 \
    --host mymainframe.example.com \
    --user SYSADM \
    --password secret \
    --hlq SYSADM \
    --output volumes.csv
```

### Pass volumes from a file

```bash
python dcollect_volumes.py \
    --volume-file volumes.txt \
    --env-id 1 \
    --host mymainframe.example.com \
    --user SYSADM \
    --password secret \
    --hlq SYSADM
```

### Use environment variables for connection details

```bash
export ZOSMF_HOST=mymainframe.example.com
export ZOSMF_USER=SYSADM
export ZOSMF_PASSWORD=secret
export ZOSMF_HLQ=SYSADM

python dcollect_volumes.py --volume-file volumes.txt --env-id 1
```

## volumes.txt format

```
# Lines starting with # are comments
SYS001
SYS002
USR001
```

## What the script does

```
  CLI args / volumes.txt
         │
         ▼
  Generates JCL (IDCAMS DCOLLECT TYPE(VOLUME))
         │
         ▼
  Submits JCL via z/OSMF REST API  ──► z/OS
         │                              IDCAMS DCOLLECT
         │                              writes binary VB records to temp dataset
         ▼
  Polls job status until OUTPUT
         │
         ▼
  Downloads binary dataset via z/OSMF REST files API
         │
         ▼
  Parses DCOLLECT 'D' (volume) records
  (DCDVOL DSECT / IDCDOUT macro layout)
         │
         ▼
  Writes  volumes.csv  (columns match VOLUMES table)
```

## Generated CSV columns

| Column | Source |
|--------|--------|
| `ENV_ID` | `--env-id` CLI argument |
| `VOLSER` | DCDVOLSR |
| `DEVICE_TYPE` | DCDDEVTP (decoded) |
| `SMS_MANAGED` | DCDDVSMS bit 0 → `Y`/`N` |
| `STORAGE_GROUP` | DCDDVSGN |
| `TOTAL_CAPACITY_MB` | DCDDVTCYL × bytes-per-cyl ÷ 1 MB |
| `FREE_SPACE_MB` | DCDDVFCYL × bytes-per-cyl ÷ 1 MB |
| `FREE_SPACE_TRK` | DCDDVFTRK |
| `FREE_SPACE_CYL` | DCDDVFCYL |
| `FREE_EXTENTS` | DCDDVFEXT |
| `LARGEST_FREE_EXT_CYL` | DCDDVLCYL |
| `LARGEST_FREE_EXT_TRK` | DCDDVLTRK |
| `PERCENT_FREE` | free_cyl / total_cyl × 100 |
| `FRAGMENTATION_INDEX` | DCDDVFIDX |

> **Note:** `VOL_ID` (IDENTITY) and `RECORDED_AT` (DEFAULT CURRENT TIMESTAMP)  
> are generated by DB2 and are **not** included in the CSV.

## DB2 LOAD command

```sql
LOAD FROM volumes.csv OF DEL
  MODIFIED BY COLDEL,
              DATEFORMAT='YYYY-MM-DD'
  INSERT INTO VOLUMES
  (ENV_ID, VOLSER, DEVICE_TYPE, SMS_MANAGED, STORAGE_GROUP,
   TOTAL_CAPACITY_MB, FREE_SPACE_MB, FREE_SPACE_TRK, FREE_SPACE_CYL,
   FREE_EXTENTS, LARGEST_FREE_EXT_CYL, LARGEST_FREE_EXT_TRK,
   PERCENT_FREE, FRAGMENTATION_INDEX)
  NONRECOVERABLE;
```

## TLS / Self-signed certificates

If your z/OSMF uses a self-signed certificate (common in test environments),
add `--no-verify` to skip validation.  **Do not use this in production.**

## Capacity calculations

The script assumes **3390 DASD** geometry for capacity conversions:

- 15 tracks/cylinder
- 56,664 bytes/track
- → 849,960 bytes/cylinder ≈ 0.81 MB/cylinder

If you have non-3390 devices, adjust `BYTES_PER_TRACK_3390` and
`TRACKS_PER_CYL_3390` in the script accordingly.

## Reference

IBM z/OS DFSMS Access Method Services Commands SC27-2678  
Appendix C — "DCOLLECT Record Formats" — DCDVOL DSECT

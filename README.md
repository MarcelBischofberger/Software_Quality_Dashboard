# Mainframe Software Quality Dashboard

A DB2-backed observability platform for z/OS environments that tracks
dataset health, volume utilization, source member history, and load module
inventory — all collected automatically from live DASD via IDCAMS DCOLLECT.

---

## Project Structure

```
Software_Quality_Dashboard/
├── database/
│   ├── schema.sql          # DB2 DDL — all tables, constraints, indexes
│   └── datamodel.md        # Data model documentation & ER diagram
└── etl/
    ├── dcollect_volumes_zoau.py   # ZOAU version (runs on z/OS) ← preferred
    ├── dcollect_volumes.py        # z/OSMF REST version (runs on any workstation)
    ├── volumes.txt                # Sample VOLSER input file
    └── README.md                  # ETL usage documentation
```

---

## Database Schema

Five DB2 tables covering the full software supply chain on z/OS:

| Table | Description |
|-------|-------------|
| `ENVIRONMENTS` | Registered z/OS sysplexes / LPARs |
| `DATASETS` | PDS and PDS/E dataset allocation & SMS attributes |
| `SOURCE_MEMBERS` | Source code members with ISPF statistics |
| `LOAD_MODULES` | Compiled load modules with binder attributes |
| `VOLUMES` | DASD volume space & VTOC metrics |

See [`database/schema.sql`](database/schema.sql) for the full DDL and
[`database/datamodel.md`](database/datamodel.md) for documentation.

---

## ETL — Volumes Collector

Populates the `VOLUMES` table by running **IDCAMS DCOLLECT TYPE(VOLUME)**
and loading the result via the **DB2 LOAD** utility.

### ZOAU version (preferred — runs on z/OS)

```bash
# Output to a USS file
python etl/dcollect_volumes_zoau.py \
    --volumes SYS001 SYS002 USR001 \
    --env-id 1 \
    --hlq SYSADM \
    --output /u/sysadm/volumes.csv

# Output directly to a z/OS dataset
python etl/dcollect_volumes_zoau.py \
    --volume-file etl/volumes.txt \
    --env-id 1 \
    --hlq SYSADM \
    --output-dsn SYSADM.SQLDASH.VOLUMES.CSV
```

**Requirements:** Python for z/OS + `zoautil_py` (Z Open Automation Utilities)

### z/OSMF REST version (runs on any workstation)

```bash
python etl/dcollect_volumes.py \
    --volumes SYS001 SYS002 \
    --env-id 1 \
    --host mymainframe.example.com \
    --user SYSADM \
    --password secret \
    --hlq SYSADM \
    --output volumes.csv
```

**Requirements:** Python 3.11+ (no third-party packages)

### DB2 LOAD

```sql
LOAD FROM volumes.csv OF DEL
  MODIFIED BY COLDEL,
  INSERT INTO VOLUMES
  (ENV_ID, VOLSER, DEVICE_TYPE, SMS_MANAGED, STORAGE_GROUP,
   TOTAL_CAPACITY_MB, FREE_SPACE_MB, FREE_SPACE_TRK, FREE_SPACE_CYL,
   FREE_EXTENTS, LARGEST_FREE_EXT_CYL, LARGEST_FREE_EXT_TRK,
   PERCENT_FREE, FRAGMENTATION_INDEX)
  NONRECOVERABLE;
```

See [`etl/README.md`](etl/README.md) for full usage documentation.

---

## Technology Stack

| Layer | Technology |
|-------|------------|
| Database | IBM Db2 for z/OS |
| ETL (z/OS native) | Python for z/OS + Z Open Automation Utilities (ZOAU) |
| ETL (workstation) | Python 3.11+ stdlib only |
| Data collection | IDCAMS DCOLLECT |
| Data loading | Db2 LOAD utility |

---

## References

- [IBM z/OS DFSMS Access Method Services Commands — SC27-2678](https://www.ibm.com/docs/en/zos/latest?topic=commands-access-method-services)
- [IBM Z Open Automation Utilities documentation](https://www.ibm.com/docs/en/zoau)
- [IBM Db2 for z/OS documentation](https://www.ibm.com/docs/en/db2-for-zos)

---

## License

MIT

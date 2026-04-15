#!/usr/bin/env python3
"""
dcollect_volumes_zoau.py
========================
Runs on z/OS (Python for z/OS + ZOAU installed).

Calls IDCAMS DCOLLECT TYPE(VOLUME) via ``mvscmd.execute``, reads the binary
output with ``zoau_io.zopen``, then writes a CSV file ready to be loaded into
the VOLUMES table with the DB2 LOAD utility.

Usage
-----
    python dcollect_volumes_zoau.py --volumes VOL001 VOL002 [OPTIONS]
    python dcollect_volumes_zoau.py --volume-file volumes.txt [OPTIONS]

Options
-------
    --volumes       VOLSER ...  One or more volume serials (1-6 chars)
    --volume-file   FILE        Text file — one VOLSER per line (# = comment)
    --env-id        INT         ENV_ID value for every row          (default: 1)
    --hlq           HLQ         HLQ for temp work dataset           (≤8 chars)
    --output        FILE        Output CSV path on USS              (default: volumes.csv)
    --output-dsn    DSN         Write CSV to a z/OS dataset instead of a USS file
    --debug                     Enable DEBUG logging

Environment Variables
---------------------
    ZOAU_HLQ        High-level qualifier for temp work datasets

DB2 LOAD Command (USS file)
---------------------------
    LOAD FROM volumes.csv OF DEL
      MODIFIED BY COLDEL,
      INSERT INTO VOLUMES
      (ENV_ID, VOLSER, DEVICE_TYPE, SMS_MANAGED, STORAGE_GROUP,
       TOTAL_CAPACITY_MB, FREE_SPACE_MB, FREE_SPACE_TRK, FREE_SPACE_CYL,
       FREE_EXTENTS, LARGEST_FREE_EXT_CYL, LARGEST_FREE_EXT_TRK,
       PERCENT_FREE, FRAGMENTATION_INDEX)
      NONRECOVERABLE;

DB2 LOAD Command (z/OS dataset)
--------------------------------
    LOAD FROM YOUR.HLQ.VOLUMES.CSV OF DEL
      MODIFIED BY COLDEL,
      INSERT INTO VOLUMES (...)
      NONRECOVERABLE;

References
----------
  IBM z/OS DFSMS Access Method Services Commands, SC27-2678
    Appendix C — DCOLLECT Record Formats (DCDVOL DSECT / IDCDOUT macro)
  IBM Z Open Automation Utilities documentation
    zoautil_py.mvscmd, zoautil_py.datasets, zoautil_py.zoau_io
"""

import argparse
import csv
import io
import logging
import os
import struct
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# ZOAU imports — must run on z/OS with ZOAU installed
# ---------------------------------------------------------------------------
try:
    from zoautil_py import mvscmd, datasets
    from zoautil_py.types import DDStatement, DatasetDefinition, FileDefinition
    from zoautil_py.zoau_io import zopen
except ImportError as _exc:                                         # pragma: no cover
    sys.exit(
        "ERROR: zoautil_py is not installed or not available.\n"
        "       This script must run on z/OS with Z Open Automation Utilities.\n"
        f"       Detail: {_exc}"
    )

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ===========================================================================
# DCOLLECT binary record parser
# ===========================================================================
# When zoau_io.zopen reads a VB sequential dataset, each iteration of the
# stream yields ONE logical record as a bytes object, with the 4-byte RDW
# already stripped by ZOAU.  This means we can directly inspect byte [0]
# for the record type without any RDW arithmetic.
#
# Volume ('D') record layout — IDCDOUT / DCDVOL DSECT
# -------------------------------------------------------
# All character fields are EBCDIC — decoded with 'cp1047'.
# All binary integers are big-endian.
#
# Offset  Len  Type    Field          Description
#    0     1   char    DCDID          Record type  = X'44' ('D')
#    1     1   char    DCDFLAGS       Flags
#    2     2   uint16  DCDLEN         Record length (already stripped by ZOAU)
#    4     6   char    DCDVOLSR       Volume serial (EBCDIC, space-padded)
#   10     4   uint32  DCDDEVTP       UCB device type (binary)
#   14     2   uint16  DCDDVDCT       Number of datasets on volume
#   16     1   char    DCDDVSFL       DASD status flags
#   17     1   char    DCDDVSMS       SMS status — bit 7 (0x80) = SMS-managed
#   18     8   char    DCDDVSGN       Storage group name (EBCDIC, space-padded)
#   26     4   uint32  DCDDVTCYL      Total cylinders
#   30     4   uint32  DCDDVFCYL      Free cylinders
#   34     4   uint32  DCDDVFTRK      Free tracks
#   38     4   uint32  DCDDVLCYL      Largest free extent in cylinders
#   42     4   uint32  DCDDVLTRK      Largest free extent in tracks
#   46     2   uint16  DCDDVFEXT      Number of free extents
#   48     2   uint16  DCDDVFIDX      Fragmentation index (0–999)
#
# Reference: SC27-2678 Appendix C
# ===========================================================================

DCOLLECT_TYPE_VOLUME = 0x44        # ASCII ordinal of 'D' in EBCDIC == X'44'
EBCDIC              = "cp1047"

# 3390 DASD geometry constants used for capacity conversions
_TRACKS_PER_CYL   = 15
_BYTES_PER_TRACK  = 56_664
_BYTES_PER_CYL    = _TRACKS_PER_CYL * _BYTES_PER_TRACK          # 849,960


# ---------------------------------------------------------------------------
# UCB device-type decoder
# ---------------------------------------------------------------------------
# The 4-byte UCB device type is a binary flag field.  The table below covers
# the most common 3390 variants.  Unknown types fall back to hex notation.
_UCB_MAP: dict[int, str] = {
    0x3010_0E00: "3390",
    0x3010_2000: "3390",
    0x3010_0001: "3390",
    0x3010_0E01: "3390-1",
    0x3010_0E02: "3390-2",
    0x3010_0E03: "3390-3",
    0x3010_0E09: "3390-9",
    0x3010_0E1C: "3390-27",
    0x3010_0E27: "3390-54",
}


def _device_type_str(ucb: int) -> str:
    return _UCB_MAP.get(ucb, f"{ucb:08X}")


# ---------------------------------------------------------------------------
# Parse a single volume record
# ---------------------------------------------------------------------------

def parse_volume_record(record: bytes) -> Optional[dict]:
    """
    Parse one DCOLLECT 'D' (volume) record.

    ``record`` is the raw bytes object returned by ``zoau_io.zopen`` —
    the RDW has already been stripped by ZOAU so byte 0 is the record type.

    Returns a dict with keys matching the VOLUMES table columns, or None
    if this is not a volume record or the record is too short.
    """
    if len(record) < 50:
        return None
    if record[0] != DCOLLECT_TYPE_VOLUME:
        return None

    try:
        volser    = record[4:10].decode(EBCDIC).strip()
        ucb_type  = struct.unpack_from(">I", record, 10)[0]
        sms_flags = record[17]
        sg_name   = record[18:26].decode(EBCDIC).strip()
        total_cyl = struct.unpack_from(">I", record, 26)[0]
        free_cyl  = struct.unpack_from(">I", record, 30)[0]
        free_trk  = struct.unpack_from(">I", record, 34)[0]
        lge_cyl   = struct.unpack_from(">I", record, 38)[0]
        lge_trk   = struct.unpack_from(">I", record, 42)[0]
        free_ext  = struct.unpack_from(">H", record, 46)[0]
        frag_idx  = struct.unpack_from(">H", record, 48)[0]
    except struct.error as exc:
        log.warning("Skipping malformed volume record: %s", exc)
        return None

    # Derived values ---------------------------------------------------------
    device_type  = _device_type_str(ucb_type)
    sms_managed  = "Y" if (sms_flags & 0x80) else "N"
    total_mb     = (total_cyl * _BYTES_PER_CYL) // (1024 * 1024)
    free_mb      = (free_cyl  * _BYTES_PER_CYL) // (1024 * 1024)
    percent_free = round(free_cyl / total_cyl * 100, 2) if total_cyl > 0 else 0.0

    return {
        "VOLSER":               volser,
        "DEVICE_TYPE":          device_type,
        "SMS_MANAGED":          sms_managed,
        "STORAGE_GROUP":        sg_name or None,
        "TOTAL_CAPACITY_MB":    total_mb,
        "FREE_SPACE_MB":        free_mb,
        "FREE_SPACE_TRK":       free_trk,
        "FREE_SPACE_CYL":       free_cyl,
        "FREE_EXTENTS":         free_ext,
        "LARGEST_FREE_EXT_CYL": lge_cyl,
        "LARGEST_FREE_EXT_TRK": lge_trk,
        "PERCENT_FREE":         percent_free,
        "FRAGMENTATION_INDEX":  frag_idx,
    }


# ===========================================================================
# IDCAMS DCOLLECT execution via mvscmd
# ===========================================================================

def _build_sysin(volumes: list[str]) -> str:
    """
    Build the IDCAMS SYSIN control card text for DCOLLECT TYPE(VOLUME).

    IDCAMS limits each continuation line to 72 characters (cols 1-72).
    Volume serials are grouped 5 per VOLUMES() sub-parameter.
    """
    lines = ["  DCOLLECT -", "    OFILE(DCOUT) -", "    TYPE(VOLUME) -"]
    chunks = [volumes[i : i + 5] for i in range(0, len(volumes), 5)]
    for idx, chunk in enumerate(chunks):
        sep = " -" if idx < len(chunks) - 1 else ""
        lines.append(f"    VOLUMES({' '.join(chunk)}){sep}")
    return "\n".join(lines) + "\n"


def run_dcollect(hlq: str, volumes: list[str]) -> str:
    """
    Execute IDCAMS DCOLLECT and return the work dataset name containing
    the binary VB output.

    Steps
    -----
    1. Write SYSIN control cards to a temporary USS file.
    2. Call ``mvscmd.execute(pgm='IDCAMS', dds=[...])``
       with DCOUT → new sequential VB dataset,
            SYSIN  → temp USS file (FileDefinition),
            SYSPRINT → temp USS file (FileDefinition).
    3. Return the dataset name for the caller to read.

    The caller is responsible for deleting the work dataset when done.
    """
    # Unique work dataset name — avoids collisions for concurrent runs
    uid      = uuid.uuid4().hex[:8].upper()
    work_dsn = f"{hlq}.DCVOL.{uid}"

    sysin_content = _build_sysin(volumes)

    # Write SYSIN to a temporary USS file so FileDefinition can point to it
    sysin_file   = tempfile.NamedTemporaryFile(
                        mode="w", suffix=".sysin",
                        encoding="cp1047",   # EBCDIC for z/OS
                        delete=False)
    sysprint_file = tempfile.NamedTemporaryFile(
                        mode="w", suffix=".sysprint",
                        delete=False)
    try:
        sysin_file.write(sysin_content)
        sysin_file.flush()
        sysin_path    = sysin_file.name
        sysprint_path = sysprint_file.name
    finally:
        sysin_file.close()
        sysprint_file.close()

    log.debug("SYSIN path : %s", sysin_path)
    log.debug("SYSPRINT path: %s", sysprint_path)
    log.debug("SYSIN content:\n%s", sysin_content)

    # DD list ----------------------------------------------------------------
    dd_list = [
        # DCOUT — new sequential VB dataset for DCOLLECT binary output
        DDStatement(
            name="DCOUT",
            definition=DatasetDefinition(
                work_dsn,
                disposition="NEW",
                normal_disposition="CATLG",
                conditional_disposition="DELETE",
                primary=1,
                primary_unit="CYL",
                secondary=1,
                secondary_unit="CYL",
                record_format="VB",
                record_length=32756,
                block_size=32760,
                type="SEQ",
            ),
        ),
        # SYSIN — DCOLLECT control cards in a USS temp file
        DDStatement(
            name="SYSIN",
            definition=FileDefinition(sysin_path),
        ),
        # SYSPRINT — capture IDCAMS messages for logging / diagnostics
        DDStatement(
            name="SYSPRINT",
            definition=FileDefinition(sysprint_path),
        ),
    ]

    log.info("Executing IDCAMS DCOLLECT for %d volume(s) …", len(volumes))
    response = mvscmd.execute(pgm="IDCAMS", dds=dd_list)

    # Log SYSPRINT output regardless of RC so the user can diagnose issues
    try:
        sysprint_text = Path(sysprint_path).read_text(errors="replace")
        if sysprint_text.strip():
            log.debug("IDCAMS SYSPRINT:\n%s", sysprint_text)
    except OSError:
        pass

    # Cleanup temp USS files
    for path in (sysin_path, sysprint_path):
        try:
            os.unlink(path)
        except OSError:
            pass

    rc = response.rc
    log.info("IDCAMS return code: %s", rc)
    if response.stderr_response:
        log.debug("mvscmd stderr: %s", response.stderr_response)

    # RC 0  → success; RC 4 → warnings (often acceptable for DCOLLECT)
    if rc > 4:
        raise RuntimeError(
            f"IDCAMS DCOLLECT failed with RC={rc}.\n"
            f"stdout: {response.stdout_response}\n"
            f"stderr: {response.stderr_response}"
        )
    if rc == 4:
        log.warning("IDCAMS returned RC=4 (warnings). Some volumes may be missing from output.")

    return work_dsn


# ===========================================================================
# Read DCOLLECT output dataset via zoau_io.zopen
# ===========================================================================

def read_dcollect_dataset(work_dsn: str) -> list[dict]:
    """
    Open the binary DCOLLECT output dataset with ``zoau_io.zopen`` and
    parse every 'D' (volume) record.

    ``zopen`` opened in ``'rb'`` mode iterates the VB dataset record-by-record,
    yielding each record as a ``bytes`` object with the RDW already stripped.
    This means we pass the bytes object directly to ``parse_volume_record``
    without any RDW unwrapping.
    """
    # Fully-qualified dataset name syntax required by zoau_io
    fqdsn = f"//{work_dsn!r}"         # e.g.  //'HLQ.DCVOL.ABCD1234'

    parsed: list[dict] = []
    total_records = 0

    log.info("Reading DCOLLECT dataset %s …", work_dsn)

    with zopen(fqdsn, "rb") as stream:
        for raw_record in stream:
            total_records += 1
            record = bytes(raw_record)          # ensure plain bytes
            result = parse_volume_record(record)
            if result:
                parsed.append(result)

    log.info(
        "Read %d total record(s); found %d volume record(s).",
        total_records,
        len(parsed),
    )
    return parsed


# ===========================================================================
# CSV writer  (USS file  OR  z/OS sequential dataset via zoau_io.zopen)
# ===========================================================================

# Columns match the VOLUMES table exactly.
# VOL_ID (IDENTITY) and RECORDED_AT (DEFAULT CURRENT TIMESTAMP) are
# generated by DB2 and must NOT appear in the LOAD input file.
_CSV_COLUMNS = [
    "ENV_ID",
    "VOLSER",
    "DEVICE_TYPE",
    "SMS_MANAGED",
    "STORAGE_GROUP",
    "TOTAL_CAPACITY_MB",
    "FREE_SPACE_MB",
    "FREE_SPACE_TRK",
    "FREE_SPACE_CYL",
    "FREE_EXTENTS",
    "LARGEST_FREE_EXT_CYL",
    "LARGEST_FREE_EXT_TRK",
    "PERCENT_FREE",
    "FRAGMENTATION_INDEX",
]


def _build_csv_text(volume_records: list[dict], env_id: int) -> str:
    """Render the volume records as CSV text (with header row)."""
    buf = io.StringIO()
    writer = csv.DictWriter(
        buf,
        fieldnames=_CSV_COLUMNS,
        extrasaction="ignore",
        delimiter=",",
        quoting=csv.QUOTE_MINIMAL,
        lineterminator="\n",
    )
    writer.writeheader()
    for rec in volume_records:
        row = dict(rec)
        row["ENV_ID"] = env_id
        writer.writerow(row)
    return buf.getvalue()


def write_csv_uss(volume_records: list[dict], env_id: int, output_path: Path):
    """Write the CSV to a USS (HFS/zFS) file — standard Python I/O."""
    csv_text = _build_csv_text(volume_records, env_id)
    output_path.write_text(csv_text, encoding="utf-8")
    log.info(
        "Wrote %d volume row(s) to USS file %s",
        len(volume_records),
        output_path,
    )


def write_csv_dataset(volume_records: list[dict], env_id: int, output_dsn: str,
                      lrecl: int = 1024):
    """
    Write the CSV to a z/OS sequential dataset via ``zoau_io.zopen``.

    The dataset is allocated as RECFM=VB so individual CSV lines of varying
    length are stored efficiently without padding.  DB2 LOAD handles VB
    sequential datasets natively when the file is specified as OF DEL.

    If the dataset already exists it will be overwritten (zopen 'w' mode
    truncates on open).  If it does not exist, ``datasets.create`` allocates
    it first.
    """
    # Allocate the output dataset if it doesn't exist
    if not datasets.exists(output_dsn):
        log.info("Creating output dataset %s …", output_dsn)
        datasets.create(
            name=output_dsn,
            type="SEQ",
            record_format="VB",
            record_length=lrecl,
            block_size=lrecl + 4,
            primary=1,
            primary_unit="CYL",
        )

    fqdsn    = f"//{output_dsn!r}"
    csv_text = _build_csv_text(volume_records, env_id)

    log.info("Writing %d volume row(s) to dataset %s …", len(volume_records), output_dsn)

    with zopen(fqdsn, "w") as ds:
        ds.write(csv_text)

    log.info("Done writing %s", output_dsn)


# ===========================================================================
# Argument parsing and validation
# ===========================================================================

def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dcollect_volumes_zoau.py",
        description=(
            "Collect DASD volume metrics via IDCAMS DCOLLECT (using ZOAU) "
            "and write a DB2-ready CSV."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # Volume selection (mutually exclusive, one is required)
    vol_grp = p.add_mutually_exclusive_group(required=True)
    vol_grp.add_argument(
        "--volumes", nargs="+", metavar="VOLSER",
        help="One or more volume serials (1-6 characters each)",
    )
    vol_grp.add_argument(
        "--volume-file", metavar="FILE",
        help="Text file with one VOLSER per line (lines starting with # are ignored)",
    )

    # DB2 context
    p.add_argument(
        "--env-id", type=int, default=1, metavar="INT",
        help="ENV_ID value embedded in every row (default: 1)",
    )

    # z/OS context
    p.add_argument(
        "--hlq", default=os.environ.get("ZOAU_HLQ"), metavar="HLQ",
        help="High-level qualifier for the temporary DCOLLECT work dataset (≤8 chars). "
             "Also reads from env var ZOAU_HLQ.",
    )

    # Output — USS file or z/OS dataset (mutually exclusive, default is USS file)
    out_grp = p.add_mutually_exclusive_group()
    out_grp.add_argument(
        "--output", default="volumes.csv", metavar="FILE",
        help="Output CSV path on USS (default: volumes.csv)",
    )
    out_grp.add_argument(
        "--output-dsn", metavar="DSN",
        help="Write CSV to this z/OS sequential dataset instead of a USS file",
    )

    p.add_argument("--debug", action="store_true", help="Enable DEBUG logging")
    return p


def _load_volumes(args) -> list[str]:
    """Collect, deduplicate, and validate volume serials."""
    raw: list[str] = []

    if args.volumes:
        raw.extend(args.volumes)

    if args.volume_file:
        vf = Path(args.volume_file)
        if not vf.exists():
            log.error("Volume file not found: %s", vf)
            sys.exit(1)
        for line in vf.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                raw.append(line)

    seen: set[str] = set()
    clean: list[str] = []
    for v in raw:
        v = v.upper().strip()
        if not v:
            continue
        if len(v) > 6:
            log.warning("VOLSER '%s' is longer than 6 characters — skipping.", v)
            continue
        if v in seen:
            log.warning("Duplicate VOLSER '%s' — skipping.", v)
            continue
        seen.add(v)
        clean.append(v)

    if not clean:
        log.error("No valid volume serials provided.")
        sys.exit(1)

    log.info("Targeting %d volume(s): %s", len(clean), ", ".join(clean))
    return clean


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = _build_arg_parser()
    args   = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    # Validate required connection params
    if not args.hlq:
        log.error(
            "Missing --hlq (or set ZOAU_HLQ environment variable).\n"
            "  The HLQ is used for the temporary DCOLLECT work dataset."
        )
        sys.exit(1)
    if len(args.hlq) > 8:
        log.error("--hlq '%s' exceeds 8 characters.", args.hlq)
        sys.exit(1)

    volumes = _load_volumes(args)

    # -----------------------------------------------------------------------
    # Step 1 — Run IDCAMS DCOLLECT via mvscmd.execute
    # -----------------------------------------------------------------------
    work_dsn: Optional[str] = None
    try:
        work_dsn = run_dcollect(hlq=args.hlq, volumes=volumes)

        # -------------------------------------------------------------------
        # Step 2 — Read binary output with zoau_io.zopen
        # -------------------------------------------------------------------
        volume_records = read_dcollect_dataset(work_dsn)

        if not volume_records:
            log.warning(
                "No volume ('D') records were found in the DCOLLECT output.\n"
                "Verify the volume serials are online and mounted."
            )
            sys.exit(3)

        # -------------------------------------------------------------------
        # Step 3 — Write CSV
        # -------------------------------------------------------------------
        if args.output_dsn:
            write_csv_dataset(volume_records, args.env_id, args.output_dsn)
            log.info(
                "Load into DB2 with:\n"
                "  LOAD FROM %s OF DEL MODIFIED BY COLDEL,\n"
                "  INSERT INTO VOLUMES\n"
                "  (ENV_ID,VOLSER,DEVICE_TYPE,SMS_MANAGED,STORAGE_GROUP,\n"
                "   TOTAL_CAPACITY_MB,FREE_SPACE_MB,FREE_SPACE_TRK,FREE_SPACE_CYL,\n"
                "   FREE_EXTENTS,LARGEST_FREE_EXT_CYL,LARGEST_FREE_EXT_TRK,\n"
                "   PERCENT_FREE,FRAGMENTATION_INDEX)\n"
                "  NONRECOVERABLE;",
                args.output_dsn,
            )
        else:
            write_csv_uss(volume_records, args.env_id, Path(args.output))
            log.info(
                "Load into DB2 with:\n"
                "  LOAD FROM %s OF DEL MODIFIED BY COLDEL,\n"
                "  INSERT INTO VOLUMES\n"
                "  (ENV_ID,VOLSER,DEVICE_TYPE,SMS_MANAGED,STORAGE_GROUP,\n"
                "   TOTAL_CAPACITY_MB,FREE_SPACE_MB,FREE_SPACE_TRK,FREE_SPACE_CYL,\n"
                "   FREE_EXTENTS,LARGEST_FREE_EXT_CYL,LARGEST_FREE_EXT_TRK,\n"
                "   PERCENT_FREE,FRAGMENTATION_INDEX)\n"
                "  NONRECOVERABLE;",
                args.output,
            )

    finally:
        # Always clean up the temporary work dataset
        if work_dsn:
            log.info("Deleting temporary work dataset %s …", work_dsn)
            try:
                datasets.delete(work_dsn)
            except Exception as exc:                                # noqa: BLE001
                log.warning("Could not delete %s: %s", work_dsn, exc)


if __name__ == "__main__":
    main()

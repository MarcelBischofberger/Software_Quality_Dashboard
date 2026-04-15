#!/usr/bin/env python3
"""
dcollect_volumes.py
====================
Calls IDCAMS DCOLLECT on a z/OS system via z/OSMF REST APIs to collect
DASD volume metrics, then writes a CSV file ready to be loaded into the
VOLUMES table via the DB2 LOAD utility.

Usage
-----
    python dcollect_volumes.py --volumes VOL001 VOL002 VOL003 [OPTIONS]
    python dcollect_volumes.py --volume-file volumes.txt         [OPTIONS]

The ENV_ID column is required for the VOLUMES table. Pass it with --env-id.

Options
-------
    --volumes     VOL ...     One or more volume serials (1-6 chars each)
    --volume-file FILE        Text file with one VOLSER per line (# = comment)
    --env-id      INT         ENV_ID value to embed in every CSV row (default: 1)
    --output      FILE        Output CSV file path          (default: volumes.csv)
    --host        HOST        z/OSMF hostname or IP
    --port        PORT        z/OSMF HTTPS port             (default: 443)
    --user        USER        z/OS user ID
    --password    PASS        z/OS password  (or set ZOSMF_PASSWORD env var)
    --hlq         HLQ         High-level qualifier for temp datasets (≤8 chars)
    --no-verify              Skip TLS certificate verification (dev/test only)

Environment Variables
---------------------
    ZOSMF_HOST      z/OSMF hostname
    ZOSMF_PORT      z/OSMF port
    ZOSMF_USER      z/OS user ID
    ZOSMF_PASSWORD  z/OS password
    ZOSMF_HLQ       High-level qualifier for temp datasets

Example
-------
    python dcollect_volumes.py \\
        --volumes SYS001 SYS002 USR001 \\
        --env-id 1 \\
        --host mymainframe.example.com \\
        --user SYSADM \\
        --password secret \\
        --hlq SYSADM \\
        --output volumes.csv

DB2 LOAD Command
----------------
    LOAD FROM volumes.csv OF DEL
      MODIFIED BY COLDEL, DATEFORMAT='YYYY-MM-DD'
                   TIMERSTAMPFORMAT='YYYY-MM-DD HH:MM:SS'
      INSERT INTO VOLUMES
      (ENV_ID, VOLSER, DEVICE_TYPE, SMS_MANAGED, STORAGE_GROUP,
       TOTAL_CAPACITY_MB, FREE_SPACE_MB, FREE_SPACE_TRK, FREE_SPACE_CYL,
       FREE_EXTENTS, LARGEST_FREE_EXT_CYL, LARGEST_FREE_EXT_TRK,
       PERCENT_FREE, FRAGMENTATION_INDEX)
"""

import argparse
import csv
import json
import logging
import os
import struct
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
import ssl
import base64
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# DCOLLECT binary record parser
# ---------------------------------------------------------------------------
# The DCOLLECT output is a sequential binary dataset of variable-length
# records.  Each record begins with a 4-byte header:
#
#   Offset  Len  Field
#   ------  ---  -----
#      0     1   Record type   ('A'=dataset, 'D'=volume, 'M'=migrated, ...)
#      1     1   Record subtype / flag byte
#      2     2   Record length (unsigned big-endian), includes the 4-byte header
#
# Volume ('D') record layout  (IDCDOUT / DCDVOL DSECT)
# -----------------------------------------------------
# All character fields are EBCDIC — they are decoded with 'cp1047'.
# All binary integers are big-endian (network byte order).
#
# Offset  Len  Type   Field name              Description
#   0      1   char   DCDID                   Record type = 'D'
#   1      1   char   DCDFLAGS                Flags
#   2      2   uint16 DCDLEN                  Record length (incl. header)
#   4      6   char   DCDVOLSR                Volume serial (EBCDIC, padded)
#  10      4   uint32 DCDDEVTP                UCB device type (binary)
#  14      2   uint16 DCDDVDCT                Number of datasets on volume
#  16      1   char   DCDDVSFL                DASD status flags
#  17      1   char   DCDDVSMS                SMS status flags  bit 0 = SMS-managed
#  18      8   char   DCDDVSGN                Storage group name (EBCDIC)
#  26      4   uint32 DCDDVTCYL               Total cylinders
#  30      4   uint32 DCDDVFCYL               Free cylinders
#  34      4   uint32 DCDDVFTRK               Free tracks
#  38      4   uint32 DCDDVLCYL               Largest free extent (cylinders)
#  42      4   uint32 DCDDVLTRK               Largest free extent (tracks)
#  46      2   uint16 DCDDVFEXT               Number of free extents
#  48      2   uint16 DCDDVFIDX               Fragmentation index (0-999)
#
# Reference: IBM z/OS DFSMS Access Method Services Commands
#            SC27-2678  Appendix C "DCOLLECT Record Formats"
# ---------------------------------------------------------------------------

DCOLLECT_REC_TYPE_VOLUME = ord('D')     # 0x44
EBCDIC = 'cp1047'

# Tracks per cylinder for 3390 DASD (15)
TRACKS_PER_CYL_3390 = 15
# Bytes per track for 3390 (56,664)
BYTES_PER_TRACK_3390 = 56_664
BYTES_PER_CYL_3390 = TRACKS_PER_CYL_3390 * BYTES_PER_TRACK_3390  # 849,960


def _ucb_device_type_str(ucb: int) -> str:
    """Convert the 4-byte UCB device type to a human-readable string."""
    # Common device type constants (first 2 bytes are the class/type code)
    # Bit pattern reference: z/OS MVS Programming: Assembler Services Reference
    device_map = {
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
    # Fallback: format as hex string
    return device_map.get(ucb, f"{ucb:08X}")


def parse_dcollect_volume_record(data: bytes) -> Optional[dict]:
    """
    Parse a single DCOLLECT volume ('D') record from raw bytes.

    Returns a dict with field names matching the VOLUMES table columns,
    or None if the record is not a volume record or is too short.
    """
    if len(data) < 50:
        return None
    if data[0] != DCOLLECT_REC_TYPE_VOLUME:
        return None

    try:
        flags     = data[1]
        rec_len   = struct.unpack_from('>H', data, 2)[0]
        volser    = data[4:10].decode(EBCDIC).strip()
        ucb_type  = struct.unpack_from('>I', data, 10)[0]
        # dataset count at offset 14 (not needed for VOLUMES table)
        sms_flag  = data[17]
        sg_name   = data[18:26].decode(EBCDIC).strip()
        total_cyl = struct.unpack_from('>I', data, 26)[0]
        free_cyl  = struct.unpack_from('>I', data, 30)[0]
        free_trk  = struct.unpack_from('>I', data, 34)[0]
        lge_cyl   = struct.unpack_from('>I', data, 38)[0]
        lge_trk   = struct.unpack_from('>I', data, 42)[0]
        free_ext  = struct.unpack_from('>H', data, 46)[0]
        frag_idx  = struct.unpack_from('>H', data, 48)[0]
    except struct.error as exc:
        log.warning("Could not parse volume record: %s", exc)
        return None

    # Derived values --------------------------------------------------------
    device_type = _ucb_device_type_str(ucb_type)
    sms_managed = 'Y' if (sms_flag & 0x80) else 'N'

    # Capacity in MB  (total cylinders → bytes → MB)
    total_mb = (total_cyl * BYTES_PER_CYL_3390) // (1024 * 1024)
    free_mb  = (free_cyl  * BYTES_PER_CYL_3390) // (1024 * 1024)

    # Percent free
    percent_free = round((free_cyl / total_cyl * 100), 2) if total_cyl > 0 else 0.0

    return {
        "VOLSER":                volser,
        "DEVICE_TYPE":           device_type,
        "SMS_MANAGED":           sms_managed,
        "STORAGE_GROUP":         sg_name if sg_name else None,
        "TOTAL_CAPACITY_MB":     total_mb,
        "FREE_SPACE_MB":         free_mb,
        "FREE_SPACE_TRK":        free_trk,
        "FREE_SPACE_CYL":        free_cyl,
        "FREE_EXTENTS":          free_ext,
        "LARGEST_FREE_EXT_CYL":  lge_cyl,
        "LARGEST_FREE_EXT_TRK":  lge_trk,
        "PERCENT_FREE":          percent_free,
        "FRAGMENTATION_INDEX":   frag_idx,
    }


def parse_dcollect_binary(data: bytes) -> list[dict]:
    """
    Walk the flat binary DCOLLECT output and extract all volume ('D') records.

    DCOLLECT writes records as a sequential file.  When transferred in binary
    (IBM Record Format VB), each 4-byte RDW (Record Descriptor Word) precedes
    the actual record data.

      RDW Bytes 0-1: total record length including the 4-byte RDW (big-endian)
      RDW Bytes 2-3: reserved (0x0000)

    Returns a list of parsed volume dicts.
    """
    volumes = []
    offset = 0
    total = len(data)

    while offset < total:
        if offset + 4 > total:
            break

        rdw_len = struct.unpack_from('>H', data, offset)[0]
        if rdw_len < 5:         # Pathological: skip a byte and try again
            offset += 1
            continue

        rec_start = offset + 4
        rec_end   = offset + rdw_len

        if rec_end > total:
            log.warning("Truncated record at offset %d; stopping.", offset)
            break

        record_data = data[rec_start:rec_end]
        parsed = parse_dcollect_volume_record(record_data)
        if parsed:
            volumes.append(parsed)

        offset = rec_end

    return volumes


# ---------------------------------------------------------------------------
# z/OSMF REST API client (no third-party dependencies)
# ---------------------------------------------------------------------------

class ZosmfClient:
    """Minimal z/OSMF REST client using stdlib urllib."""

    def __init__(self, host: str, port: int, user: str, password: str, verify_ssl: bool = True):
        self.base = f"https://{host}:{port}"
        creds = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {creds}",
            "Content-Type":  "application/json",
            "X-CSRF-ZOSMF-HEADER": "",      # Required anti-CSRF header
        }
        self.ssl_ctx = ssl.create_default_context()
        if not verify_ssl:
            self.ssl_ctx.check_hostname = False
            self.ssl_ctx.verify_mode = ssl.CERT_NONE

    def _request(self, method: str, path: str, body: Optional[dict] = None,
                 extra_headers: Optional[dict] = None, binary_response: bool = False):
        url = self.base + path
        data = json.dumps(body).encode() if body else None
        headers = dict(self.headers)
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=120) as resp:
                if binary_response:
                    return resp.status, resp.read(), dict(resp.headers)
                return resp.status, json.loads(resp.read()), dict(resp.headers)
        except urllib.error.HTTPError as exc:
            body_text = exc.read().decode(errors="replace")
            raise RuntimeError(f"HTTP {exc.code} {exc.reason}: {body_text}") from exc

    # --- Jobs (JES) ---------------------------------------------------------

    def submit_jcl(self, jcl: str) -> str:
        """Submit JCL text and return the JES job ID."""
        url = self.base + "/zosmf/restjobs/jobs"
        headers = {k: v for k, v in self.headers.items()}
        headers["Content-Type"] = "text/plain"
        req = urllib.request.Request(url, data=jcl.encode(), headers=headers, method="PUT")
        with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=120) as r:
            resp = json.loads(r.read())
        job_id = resp["jobid"]
        log.info("Submitted job %s (%s)", job_id, resp.get("jobname", ""))
        return job_id

    def wait_for_job(self, job_id: str, poll_interval: float = 3.0, max_wait: float = 300.0) -> dict:
        """Poll until the job completes; return the final job status dict."""
        deadline = time.time() + max_wait
        while time.time() < deadline:
            _, resp, _ = self._request("GET", f"/zosmf/restjobs/jobs/{job_id}")
            status = resp.get("status", "")
            log.debug("Job %s status: %s", job_id, status)
            if status == "OUTPUT":
                return resp
            if status in ("ABEND", "JCLERR"):
                raise RuntimeError(f"Job {job_id} ended with status {status}")
            time.sleep(poll_interval)
        raise TimeoutError(f"Job {job_id} did not complete within {max_wait}s")

    def get_job_spool_file(self, job_id: str, ddname: str, binary: bool = False) -> bytes:
        """Retrieve the content of a spool DD by name."""
        _, files, _ = self._request("GET", f"/zosmf/restjobs/jobs/{job_id}/files")
        target = next((f for f in files if f.get("ddname") == ddname), None)
        if not target:
            available = [f.get("ddname") for f in files]
            raise KeyError(f"DD '{ddname}' not found in job {job_id}. Available: {available}")
        file_id = target["id"]
        path = f"/zosmf/restjobs/jobs/{job_id}/files/{file_id}/records"
        if binary:
            _, raw, _ = self._request("GET", path, binary_response=True,
                                      extra_headers={"Accept": "application/octet-stream"})
            return raw
        _, text, _ = self._request("GET", path,
                                   extra_headers={"Accept": "text/plain"})
        return text  # already decoded

    # --- Datasets -----------------------------------------------------------

    def read_dataset_binary(self, dsn: str) -> bytes:
        """Read a sequential DASD dataset in binary mode."""
        encoded = urllib.parse.quote(dsn.upper(), safe="")
        _, raw, _ = self._request(
            "GET",
            f"/zosmf/restfiles/ds/{encoded}",
            binary_response=True,
            extra_headers={"Accept": "application/octet-stream",
                           "X-IBM-Data-Type": "binary"},
        )
        return raw

    def delete_dataset(self, dsn: str):
        """Delete a DASD dataset (best-effort cleanup)."""
        encoded = urllib.parse.quote(dsn.upper(), safe="")
        try:
            self._request("DELETE", f"/zosmf/restfiles/ds/{encoded}")
        except RuntimeError as exc:
            log.warning("Could not delete %s: %s", dsn, exc)


# ---------------------------------------------------------------------------
# JCL generation
# ---------------------------------------------------------------------------

def build_dcollect_jcl(hlq: str, volumes: list[str], user: str) -> str:
    """
    Generate JCL that runs IDCAMS DCOLLECT TYPE(VOLUME) for the given volumes.

    The DCOLLECT output is directed to  <HLQ>.DCOLLECT.OUTPUT  (a VSAM ESDS).
    A second step copies that to a sequential dataset  <HLQ>.DCOLLECT.SEQ
    so it can be retrieved via the z/OSMF files REST API.
    """
    out_vsam  = f"{hlq}.DCOLLECT.OUTPUT"
    out_seq   = f"{hlq}.DCOLLECT.SEQ"

    # Build VOLUMES() keyword — IDCAMS accepts up to 255 volume serials
    vol_chunks = [volumes[i:i+5] for i in range(0, len(volumes), 5)]
    vol_lines  = []
    for chunk in vol_chunks:
        vol_lines.append("               VOLUMES(" + " ".join(chunk) + ")")
    vol_keyword = " -\n".join(vol_lines)

    jcl = f"""\
//DCOLVOL  JOB  (ACCT),'DCOLLECT VOLS',CLASS=A,MSGCLASS=H,
//             MSGLEVEL=(1,1),NOTIFY=&SYSUID
//*---------------------------------------------------------------------
//* Step 1: Allocate and populate the DCOLLECT VSAM output dataset
//*---------------------------------------------------------------------
//STEP1    EXEC PGM=IDCAMS
//SYSPRINT DD   SYSOUT=*
//DCOUT    DD   DSN={out_vsam},
//             DISP=(NEW,CATLG,DELETE),
//             SPACE=(CYL,(1,1)),
//             DSORG=PS,RECFM=VB,LRECL=32756,BLKSIZE=0
//SYSIN    DD   *
  DCOLLECT -
    OFILE(DCOUT) -
    TYPE(VOLUME) -
{vol_keyword}
/*
//*---------------------------------------------------------------------
//* Step 2: Copy VSAM to sequential so z/OSMF files API can read it
//*---------------------------------------------------------------------
//STEP2    EXEC PGM=IDCAMS,COND=(0,LT)
//SYSPRINT DD   SYSOUT=*
//DCIN     DD   DSN={out_vsam},DISP=SHR
//DCSEQ    DD   DSN={out_seq},
//             DISP=(NEW,CATLG,DELETE),
//             SPACE=(CYL,(1,1),RLSE),
//             DSORG=PS,RECFM=VB,LRECL=32756,BLKSIZE=0
//SYSIN    DD   *
  REPRO INFILE(DCIN) OUTFILE(DCSEQ)
/*
//*---------------------------------------------------------------------
//* Step 3: Clean up the VSAM work file
//*---------------------------------------------------------------------
//STEP3    EXEC PGM=IDCAMS,COND=(0,LT)
//SYSPRINT DD   SYSOUT=*
//SYSIN    DD   *
  DELETE {out_vsam}
/*
"""
    return jcl


# ---------------------------------------------------------------------------
# CSV writer
# ---------------------------------------------------------------------------

# Columns match the VOLUMES table exactly (VOL_ID and RECORDED_AT are
# generated automatically by DB2 and should NOT be in the load file)
CSV_COLUMNS = [
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


def write_csv(volumes: list[dict], env_id: int, output_path: Path):
    """Write the list of parsed volume records to a CSV file for DB2 LOAD."""
    with output_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=CSV_COLUMNS,
            extrasaction="ignore",
            delimiter=",",
            quoting=csv.QUOTE_MINIMAL,
        )
        writer.writeheader()
        for vol in volumes:
            row = dict(vol)          # copy
            row["ENV_ID"] = env_id   # inject ENV_ID
            writer.writerow(row)

    log.info("Wrote %d volume records to %s", len(volumes), output_path)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def load_volume_list(args) -> list[str]:
    """Collect and validate volume serials from CLI or file."""
    vols: list[str] = []

    if args.volumes:
        vols.extend(args.volumes)

    if args.volume_file:
        path = Path(args.volume_file)
        if not path.exists():
            log.error("Volume file not found: %s", path)
            sys.exit(1)
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                vols.append(line)

    # Validate
    seen = set()
    clean = []
    for v in vols:
        v = v.upper().strip()
        if not v:
            continue
        if len(v) > 6:
            log.warning("VOLSER '%s' exceeds 6 characters — skipping", v)
            continue
        if v in seen:
            log.warning("Duplicate VOLSER '%s' — skipping", v)
            continue
        seen.add(v)
        clean.append(v)

    if not clean:
        log.error("No valid volume serials provided.")
        sys.exit(1)

    log.info("Processing %d volume(s): %s", len(clean), ", ".join(clean))
    return clean


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Collect DASD volume metrics via IDCAMS DCOLLECT and write a DB2-ready CSV.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # Volume selection
    vol_group = p.add_mutually_exclusive_group(required=True)
    vol_group.add_argument("--volumes", nargs="+", metavar="VOLSER",
                           help="One or more volume serials (1-6 chars each)")
    vol_group.add_argument("--volume-file", metavar="FILE",
                           help="Text file with one VOLSER per line (# = comment)")

    # DB2 target
    p.add_argument("--env-id", type=int, default=1, metavar="INT",
                   help="ENV_ID value to embed in every row (default: 1)")

    # z/OSMF connection
    p.add_argument("--host",     default=os.environ.get("ZOSMF_HOST"),  metavar="HOST")
    p.add_argument("--port",     default=int(os.environ.get("ZOSMF_PORT", 443)), type=int)
    p.add_argument("--user",     default=os.environ.get("ZOSMF_USER"),  metavar="USER")
    p.add_argument("--password", default=os.environ.get("ZOSMF_PASSWORD"), metavar="PASS")
    p.add_argument("--hlq",      default=os.environ.get("ZOSMF_HLQ"),   metavar="HLQ",
                   help="High-level qualifier for temporary work datasets (≤8 chars)")
    p.add_argument("--no-verify", action="store_true",
                   help="Disable TLS certificate verification (dev/test only)")

    # Output
    p.add_argument("--output", default="volumes.csv", metavar="FILE",
                   help="Output CSV file path (default: volumes.csv)")

    # Debug
    p.add_argument("--debug", action="store_true", help="Enable DEBUG logging")

    return p


def validate_connection_args(args):
    missing = []
    if not args.host:
        missing.append("--host (or ZOSMF_HOST)")
    if not args.user:
        missing.append("--user (or ZOSMF_USER)")
    if not args.password:
        missing.append("--password (or ZOSMF_PASSWORD)")
    if not args.hlq:
        missing.append("--hlq (or ZOSMF_HLQ)")
    if missing:
        log.error("Missing required connection arguments:\n  " + "\n  ".join(missing))
        sys.exit(1)
    if len(args.hlq) > 8:
        log.error("HLQ '%s' exceeds 8 characters.", args.hlq)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = build_arg_parser()
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    validate_connection_args(args)

    volumes   = load_volume_list(args)
    output    = Path(args.output)
    client    = ZosmfClient(args.host, args.port, args.user, args.password,
                            verify_ssl=not args.no_verify)

    # -----------------------------------------------------------------------
    # 1. Build and submit JCL
    # -----------------------------------------------------------------------
    jcl = build_dcollect_jcl(args.hlq, volumes, args.user)
    log.debug("Generated JCL:\n%s", jcl)

    log.info("Submitting DCOLLECT job to %s:%s …", args.host, args.port)
    job_id = client.submit_jcl(jcl)

    # -----------------------------------------------------------------------
    # 2. Wait for completion
    # -----------------------------------------------------------------------
    log.info("Waiting for job %s to complete …", job_id)
    job_info = client.wait_for_job(job_id, poll_interval=5.0, max_wait=600.0)
    rc = job_info.get("retcode", "UNKNOWN")
    log.info("Job %s finished — return code: %s", job_id, rc)

    if rc not in ("CC 0000", "CC 0004"):
        log.error("Job ended with RC=%s. Check SYSPRINT for details.", rc)
        sys.exit(2)

    # -----------------------------------------------------------------------
    # 3. Retrieve the binary sequential output dataset
    # -----------------------------------------------------------------------
    out_seq = f"{args.hlq}.DCOLLECT.SEQ"
    log.info("Retrieving dataset %s …", out_seq)
    raw_data = client.read_dataset_binary(out_seq)
    log.info("Downloaded %d bytes of DCOLLECT data.", len(raw_data))

    # -----------------------------------------------------------------------
    # 4. Clean up the work dataset
    # -----------------------------------------------------------------------
    log.info("Deleting temporary dataset %s …", out_seq)
    client.delete_dataset(out_seq)

    # -----------------------------------------------------------------------
    # 5. Parse the binary records
    # -----------------------------------------------------------------------
    log.info("Parsing DCOLLECT records …")
    parsed_volumes = parse_dcollect_binary(raw_data)
    log.info("Parsed %d volume record(s).", len(parsed_volumes))

    if not parsed_volumes:
        log.warning("No volume records found in DCOLLECT output. "
                    "Verify the volume serials are online and the ID has READ access.")
        sys.exit(3)

    # -----------------------------------------------------------------------
    # 6. Write CSV
    # -----------------------------------------------------------------------
    write_csv(parsed_volumes, args.env_id, output)
    log.info("Done. Load the CSV into DB2 with:\n"
             "  LOAD FROM %s OF DEL MODIFIED BY COLDEL, DATEFORMAT='YYYY-MM-DD'\n"
             "  INSERT INTO VOLUMES\n"
             "  (ENV_ID,VOLSER,DEVICE_TYPE,SMS_MANAGED,STORAGE_GROUP,\n"
             "   TOTAL_CAPACITY_MB,FREE_SPACE_MB,FREE_SPACE_TRK,FREE_SPACE_CYL,\n"
             "   FREE_EXTENTS,LARGEST_FREE_EXT_CYL,LARGEST_FREE_EXT_TRK,\n"
             "   PERCENT_FREE,FRAGMENTATION_INDEX)", output)


if __name__ == "__main__":
    main()

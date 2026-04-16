/* REXX */
/***REXX*****REXX*****REXX*****REXX*****REXX*****REXX*****REXX*****/
/*                                                                   */
/*  GETMSTAT  —  Mainframe Software Quality Dashboard               */
/*               Read PDS/E member statistics from the directory    */
/*                                                                   */
/*  Purpose:                                                         */
/*    Reads the PDS/E directory DIRECTLY using ISPF dialog services  */
/*    (no utilities, no JCL).  Works for both source libraries       */
/*    (ISPF statistics) and load libraries (binder attributes).      */
/*                                                                   */
/*  Syntax:                                                          */
/*    GETMSTAT  'dataset.name'  ds_id  [output.dataset]             */
/*                                                                   */
/*  Arguments:                                                       */
/*    dataset.name  — Fully qualified dataset name                   */
/*                    (with or without enclosing quotes)             */
/*    ds_id         — DS_ID key from the DATASETS table             */
/*    output.dataset — Optional sequential output dataset for CSV   */
/*                    Default: write to console (SYSPRINT)          */
/*                                                                   */
/*  Output CSV columns:                                              */
/*    Source library → SOURCE_MEMBERS table                         */
/*      MEMBER_NAME | VERSION_NUM | MOD_LEVEL | CREATION_DATE |     */
/*      LAST_MOD_DATE | LAST_MOD_TIME | CURRENT_LINES |             */
/*      INITIAL_LINES | MODIFIED_LINES | USERID | DS_ID             */
/*                                                                   */
/*    Load library   → LOAD_MODULES table                           */
/*      MEMBER_NAME | ALIAS_INDICATOR | ALIAS_OF | MODULE_SIZE |    */
/*      AMODE | RMODE | AUTH_CODE | DS_ID                           */
/*                                                                   */
/*  ISPF directory-entry byte layouts:                               */
/*                                                                   */
/*    SOURCE — user data (ZURSTAT), 30 bytes (15 halfwords)         */
/*    ────────────────────────────────────────────────────────────   */
/*    Byte  Len  Description                                         */
/*       1    1  VV — version number (binary 0-99)                  */
/*       2    1  MM — modification level (binary 0-99)              */
/*       3    2  Flags  (X'8000' = SCLM controlled)                 */
/*       5    2  Created year  (binary, 2-digit, e.g. 24 = 2024)    */
/*       7    2  Created Julian day (binary, 1-366)                 */
/*       9    2  Changed year  (binary, 2-digit)                    */
/*      11    2  Changed Julian day (binary, 1-366)                 */
/*      13    1  Changed hour  (binary, 0-23)                       */
/*      14    1  Changed minute (binary, 0-59)                      */
/*      15    2  Current # records SIZE (binary, big-endian)        */
/*      17    2  Initial # records INIT (binary, big-endian)        */
/*      19    2  Modified # records MOD  (binary, big-endian)       */
/*      21    8  User ID of last modifier (EBCDIC, blank-padded)    */
/*      29    2  Extended SIZE high-order (for > 65,535 line mbrs)  */
/*                                                                   */
/*    LOAD — user data (ZURSTAT), typically 14 halfwords = 28 bytes  */
/*    ────────────────────────────────────────────────────────────   */
/*    Byte  Len  Description                                         */
/*       1    3  Note-list TTR  (3-byte relative track address)     */
/*       4    1  Number of notes                                     */
/*       5    1  Attribute byte 1                                    */
/*                Bit X'80' = Alias entry                            */
/*                Bit X'10' = SCTR (scatter load)                   */
/*                Bit X'08' = OVLY (overlay)                        */
/*                Bit X'04' = TEST attribute                         */
/*                Bit X'02' = ONLY (loadable only via link-edit)    */
/*       6    1  Attribute byte 2                                    */
/*                Bit X'80' = REUS (reusable)                        */
/*                Bit X'40' = RENT (reentrant)                       */
/*                Bit X'10' = APF authorized (AC=1)                  */
/*                Bit X'04' = AMODE(31) set by binder               */
/*                Bit X'02' = RMODE(ANY) set by binder              */
/*       7    2  Module size in 8-byte doubleword blocks (binary)   */
/*       9    2  Entry-point offset in 8-byte blocks (binary)       */
/*      11    2  Number of RLD (reloc dictionary) entries (binary)  */
/*      13+      Extended binder attributes (variable)              */
/*                                                                   */
/*  Reference:  z/OS ISPF Services Guide  SC19-3519                 */
/*              z/OS MVS Programming: Authorized Assembler SVCs     */
/*                                                                   */
/***REXX*****REXX*****REXX*****REXX*****REXX*****REXX*****REXX*****/

signal on novalue   name bad_novalue
signal on syntax    name bad_syntax
signal on error     name bad_error

/*--------------------------------------------------------------------*/
/* Initialise global counters and output stem                         */
/*--------------------------------------------------------------------*/
ok_count   = 0          /* members successfully processed             */
skip_count = 0          /* members skipped (errors or unsupported)   */
out.0      = 0          /* output line stem                           */
max_rc     = 0          /* highest return code seen                   */

/*--------------------------------------------------------------------*/
/* Parse arguments                                                    */
/*--------------------------------------------------------------------*/
parse arg rawdsn ds_id out_dsn .

if rawdsn = '' | ds_id = '' then do
  call say_msg 'ERROR' 'Syntax:  GETMSTAT  dataset.name  ds_id  [output.dsn]'
  exit 8
end

if \DATATYPE(ds_id,'N') then do
  call say_msg 'ERROR' 'ds_id must be a numeric value — got: ' ds_id
  exit 8
end
ds_id = ds_id + 0   /* strip leading zeros */

/* Normalise dataset name — remove any enclosing quotes and           */
/* upper-case it; then re-quote for system calls                      */
dsname = STRIP(rawdsn,"B","'")
dsname = TRANSLATE(dsname)            /* upper case                   */
fqdsn  = "'"dsname"'"                 /* fully-qualified form         */

if out_dsn <> '' then
  out_dsn = TRANSLATE(STRIP(out_dsn,"B","'"))

call say_msg 'INFO' 'Dataset  :' dsname
call say_msg 'INFO' 'DS_ID    :' ds_id
if out_dsn <> '' then
  call say_msg 'INFO' 'Output   :' out_dsn

/*--------------------------------------------------------------------*/
/* LISTDSI — get dataset attributes to determine library type         */
/*--------------------------------------------------------------------*/
ldrc = LISTDSI(fqdsn 'DIRECTORY SMSINFO')
if ldrc > 4 then do
  call say_msg 'ERROR' 'LISTDSI failed for' dsname '— RC=' ldrc SYSMSGLVL2
  exit 8
end

call say_msg 'INFO' 'DSORG    :' SYSDSORG
call say_msg 'INFO' 'RECFM    :' SYSRECFM
call say_msg 'INFO' 'LRECL    :' SYSLRECL
call say_msg 'INFO' 'DSNTYPE  :' SYSDSSMS

if SYSDSORG <> 'PO' then do
  call say_msg 'ERROR' dsname 'is not a partitioned dataset (DSORG='SYSDSORG')'
  exit 8
end

/* RECFM=U → load library; anything else is treated as source        */
if SYSRECFM = 'U' then
  libtype = 'LOAD'
else
  libtype = 'SOURCE'

call say_msg 'INFO' 'Library  :' libtype

/*--------------------------------------------------------------------*/
/* Verify ISPF is active — LMINIT will fail with RC=20 if not        */
/*--------------------------------------------------------------------*/
address ISPEXEC
"CONTROL ERRORS RETURN"         /* prevent ISPF error dialogs         */

"LMINIT DATAID(DATAID) DATASET("fqdsn") ENQ(SHR)"
lminit_rc = rc
if lminit_rc = 20 then do
  call say_msg 'ERROR' 'ISPF is not active. GETMSTAT requires an ISPF session.'
  call say_msg 'ERROR' 'Run this exec from the ISPF command line or via ISPSTART.'
  exit 12
end
if lminit_rc <> 0 then do
  call say_msg 'ERROR' 'LMINIT failed for' dsname '— RC=' lminit_rc
  exit 8
end
did = DATAID       /* data ID returned by LMINIT                      */

"LMOPEN DATAID("did") OPTION(INPUT)"
if rc <> 0 then do
  call say_msg 'ERROR' 'LMOPEN failed for' dsname '— RC=' rc
  "LMFREE DATAID("did")"
  exit 8
end

/*--------------------------------------------------------------------*/
/* Write CSV header line                                              */
/*--------------------------------------------------------------------*/
if libtype = 'SOURCE' then
  call add_line 'MEMBER_NAME,VERSION_NUM,MOD_LEVEL,CREATION_DATE,' ||,
                'LAST_MOD_DATE,LAST_MOD_TIME,CURRENT_LINES,' ||,
                'INITIAL_LINES,MODIFIED_LINES,USERID,DS_ID'
else
  call add_line 'MEMBER_NAME,ALIAS_INDICATOR,ALIAS_OF,MODULE_SIZE,' ||,
                'AMODE,RMODE,AUTH_CODE,DS_ID'

/*--------------------------------------------------------------------*/
/* MAIN LOOP — iterate through directory entries via LMMLIST          */
/*--------------------------------------------------------------------*/
member = ' '

do forever
  /*------------------------------------------------------------------*/
  /* LMMLIST — advance to next member entry                           */
  /* STATS(YES) causes ISPF to read ISPF statistics from the          */
  /* directory user data and populate the ZL* dialog variables.       */
  /* For LOAD libraries we still call with STATS(YES) so that         */
  /* ZLALIAS and ZLALIASOF are populated from the binder attribute     */
  /* flag (alias bit in user-data byte 5).                            */
  /*------------------------------------------------------------------*/
  if libtype = 'SOURCE' then
    "LMMLIST DATAID("did") OPTION(LIST) MEMBER(MEMBER) STATS(YES)"
  else
    "LMMLIST DATAID("did") OPTION(LIST) MEMBER(MEMBER) STATS(YES)"

  lmmlist_rc = rc

  select
    when lmmlist_rc = 8  then leave          /* end of member list   */
    when lmmlist_rc = 4  then do             /* member entry but      */
      call say_msg 'WARN' 'LMMLIST RC=4 for' member '— skipping'
      skip_count = skip_count + 1
      iterate
    end
    when lmmlist_rc <> 0 then do
      call say_msg 'ERROR' 'LMMLIST failed — RC=' lmmlist_rc
      call set_max_rc 8
      leave
    end
    otherwise nop
  end

  /*------------------------------------------------------------------*/
  /* Process member based on library type                             */
  /*------------------------------------------------------------------*/
  if libtype = 'SOURCE' then
    call process_source member
  else
    call process_load member

end  /* end LMMLIST loop */

/*--------------------------------------------------------------------*/
/* Release LMMLIST resources                                          */
/*--------------------------------------------------------------------*/
"LMMLIST DATAID("did") OPTION(FREE)"

/*--------------------------------------------------------------------*/
/* Close and free the data ID                                         */
/*--------------------------------------------------------------------*/
"LMCLOSE DATAID("did")"
"LMFREE  DATAID("did")"

/*--------------------------------------------------------------------*/
/* Write output                                                        */
/*--------------------------------------------------------------------*/
call flush_output

call say_msg 'INFO' '─────────────────────────────────────────────────'
call say_msg 'INFO' 'Members processed :' ok_count
call say_msg 'INFO' 'Members skipped   :' skip_count
call say_msg 'INFO' 'Max RC            :' max_rc

exit max_rc


/*====================================================================*/
/* PROCESS_SOURCE - Extract ISPF statistics from source member        */
/*====================================================================*/
/* After LMMLIST STATS(YES), ISPF has already read the user data      */
/* from the directory entry and populated these dialog variables:      */
/*                                                                    */
/*   ZLVERS   — version (VV) as 2-char string  e.g. '01'             */
/*   ZLMOD    — modification level (MM)        e.g. '03'             */
/*   ZLCDATE  — creation date  'YYYY/MM/DD' or 'YY/MM/DD'            */
/*   ZLMDATE  — last mod date  same format                            */
/*   ZLMTIME  — last mod time  'HH:MM'                               */
/*   ZLCNORC  — current # of records (SIZE)                           */
/*   ZLINORC  — initial # of records (INIT)                          */
/*   ZLMNORC  — # of records modified (MOD)                          */
/*   ZLUSERID — userid of last modifier (up to 8 chars)              */
/*   ZLALIAS  — 'Y' if this entry is an alias, ' ' otherwise         */
/*   ZLALIASOF— name of primary member (when ZLALIAS='Y')            */
/*====================================================================*/
process_source:
  parse arg mbr .

  /* ISPF date may be 'YY/MM/DD' or 'YYYY/MM/DD' */
  cdate = format_ispf_date(ZLCDATE)
  mdate = format_ispf_date(ZLMDATE)
  mtime = ZLMTIME                   /* already 'HH:MM' format        */

  /* Strip and validate numeric fields                                */
  vv     = STRIP(ZLVERS)
  mm     = STRIP(ZLMOD)
  clines = STRIP(ZLCNORC)
  ilines = STRIP(ZLINORC)
  mlines = STRIP(ZLMNORC)
  uid    = STRIP(ZLUSERID)

  /* Build CSV record                                                 */
  csv = csv_field(mbr)      ','  ,
        csv_field(vv)       ','  ,
        csv_field(mm)       ','  ,
        csv_field(cdate)    ','  ,
        csv_field(mdate)    ','  ,
        csv_field(mtime)    ','  ,
        csv_field(clines)   ','  ,
        csv_field(ilines)   ','  ,
        csv_field(mlines)   ','  ,
        csv_field(uid)      ','  ,
        ds_id

  call add_line csv
  ok_count = ok_count + 1

return


/*====================================================================*/
/* PROCESS_LOAD - Extract binder attributes from load module          */
/*====================================================================*/
/* LMMLIST STATS(YES) sets ZLALIAS and ZLALIASOF for load modules.   */
/* For the remaining attributes (AMODE, RMODE, size, AUTH_CODE) we   */
/* call LMMFIND to position to the member, then LMMSTAT OPTION(GET)  */
/* to retrieve the raw directory user data in ZURSTAT.               */
/*                                                                    */
/* We then parse ZURSTAT according to the load-module user-data       */
/* layout documented in the header of this exec.                      */
/*====================================================================*/
process_load:
  parse arg mbr .

  /* Alias info from LMMLIST                                          */
  alias_ind = STRIP(ZLALIAS)
  if alias_ind = '' then alias_ind = 'N'
  alias_of  = STRIP(ZLALIASOF)

  /* Default values in case ZURSTAT is unavailable                    */
  module_size = ''
  amode       = ''
  rmode       = ''
  auth_code   = 0

  /*------------------------------------------------------------------*/
  /* Position to the member and get raw directory user data           */
  /*------------------------------------------------------------------*/
  "LMMFIND DATAID("did") MEMBER("mbr") STATS(YES)"
  lmmfind_rc = rc

  if lmmfind_rc = 0 then do
    /*----------------------------------------------------------------*/
    /* LMMSTAT OPTION(GET) — retrieve raw user data into ZURSTAT      */
    /* ZURSTAT contains the binary directory user data bytes;         */
    /* its length = (C_byte & X'1F') * 2 bytes.                      */
    /*----------------------------------------------------------------*/
    "LMMSTAT DATAID("did") OPTION(GET) MEMBER("mbr")"
    lmmstat_rc = rc

    if lmmstat_rc = 0 & LENGTH(ZURSTAT) >= 8 then do
      /*--------------------------------------------------------------*/
      /* Parse load-module user data (see layout in program header)   */
      /*--------------------------------------------------------------*/
      /* Bytes 5/6: attribute bytes                                   */
      attr1 = SUBSTR(ZURSTAT, 5, 1)
      attr2 = SUBSTR(ZURSTAT, 6, 1)

      /* Alias indicator from attribute byte 1, bit X'80'             */
      if BITAND(attr1, 'FF'x) <> '00'x then do   /* safety check     */
        if BITAND(attr1, '80'x) <> '00'x then alias_ind = 'Y'
      end

      /* AMODE — bit X'04' of attr2 = AMODE(31)                      */
      if BITAND(attr2, '04'x) <> '00'x then
        amode = '31'
      else
        amode = '24'
      /* Note: AMODE(64) and AMODE(ANY) require extended binder data  */
      /* beyond the base 28 bytes — extend parsing if ZURSTAT longer  */
      if LENGTH(ZURSTAT) >= 15 then do
        /* Some binder levels encode AMODE(64) or ANY in byte 13+     */
        extended = SUBSTR(ZURSTAT, 13, 1)
        if BITAND(extended, '80'x) <> '00'x then amode = '64'
        if BITAND(extended, '40'x) <> '00'x then amode = 'ANY'
      end

      /* RMODE — bit X'02' of attr2 = RMODE(ANY)                     */
      if BITAND(attr2, '02'x) <> '00'x then
        rmode = 'ANY'
      else
        rmode = '24'

      /* AUTH_CODE — bit X'10' of attr2 = APF authorized (AC=1)      */
      if BITAND(attr2, '10'x) <> '00'x then
        auth_code = 1
      else
        auth_code = 0

      /* MODULE_SIZE — bytes 7-8: size in 8-byte (doubleword) blocks  */
      if LENGTH(ZURSTAT) >= 8 then do
        size_blocks = C2D(SUBSTR(ZURSTAT, 7, 2))
        module_size = size_blocks * 8       /* convert to bytes       */
      end

    end  /* LMMSTAT OK */
    else if lmmstat_rc <> 0 then
      call say_msg 'WARN' 'LMMSTAT failed for' mbr '— RC=' lmmstat_rc

  end  /* LMMFIND OK */
  else if lmmfind_rc <> 0 then
    call say_msg 'WARN' 'LMMFIND failed for' mbr '— RC=' lmmfind_rc, ,
                        '(attributes will be empty)'

  /* Build CSV record                                                  */
  csv = csv_field(mbr)         ','  ,
        csv_field(alias_ind)   ','  ,
        csv_field(alias_of)    ','  ,
        csv_field(module_size) ','  ,
        csv_field(amode)       ','  ,
        csv_field(rmode)       ','  ,
        auth_code              ','  ,
        ds_id

  call add_line csv
  ok_count = ok_count + 1

return


/*====================================================================*/
/* FORMAT_ISPF_DATE — convert ISPF date to YYYY-MM-DD                */
/*====================================================================*/
/* ISPF returns dates as 'YY/MM/DD' (old) or 'YYYY/MM/DD' (modern)  */
/* We return 'YYYY-MM-DD' for DB2.                                   */
/* A 2-digit year < 70 is treated as 20xx; >= 70 as 19xx.           */
/*====================================================================*/
format_ispf_date: procedure
  parse arg raw_date

  raw_date = STRIP(raw_date)
  if raw_date = '' | raw_date = '0000/00/00' | raw_date = '00/00/00' then
    return ''

  /* Split on slash                                                   */
  parse value raw_date with p1 '/' p2 '/' p3

  if LENGTH(p1) = 4 then do
    /* Already 4-digit year: YYYY/MM/DD                              */
    yyyy = p1
    mm   = p2
    dd   = p3
  end
  else do
    /* 2-digit year: YY/MM/DD                                        */
    yy = p1
    mm = p2
    dd = p3
    if yy < 70 then
      yyyy = '20' || RIGHT(yy,2,'0')
    else
      yyyy = '19' || RIGHT(yy,2,'0')
  end

  return yyyy'-'RIGHT(mm,2,'0')'-'RIGHT(dd,2,'0')


/*====================================================================*/
/* CSV_FIELD — quote a field value if it contains a comma or quote   */
/*====================================================================*/
csv_field: procedure
  parse arg val
  val = STRIP(val)
  if val = '' then return ''
  if POS(',',val) > 0 | POS('"',val) > 0 then do
    val = '"' || CHANGESTR('"',val,'""') || '"'
  end
  return val


/*====================================================================*/
/* ADD_LINE — append a line to the output stem                       */
/*====================================================================*/
add_line:
  parse arg line
  n      = out.0 + 1
  out.n  = line
  out.0  = n
return


/*====================================================================*/
/* FLUSH_OUTPUT — write collected CSV lines to dest or console       */
/*====================================================================*/
flush_output:

  if out_dsn = '' then do
    /* Write to console                                               */
    do i = 1 to out.0
      say out.i
    end
    return
  end

  /* Write to output dataset                                          */
  address TSO
  "ALLOC FI(OUTDD) DA('"out_dsn"') SHR REUSE"
  alloc_rc = rc
  if alloc_rc <> 0 then do
    /* Try to create the dataset first                                */
    "ALLOC FI(OUTDD) DA('"out_dsn"')" ,
          "NEW CATALOG" ,
          "DSORG(PS) RECFM(V,B) LRECL(1024) BLKSIZE(0)" ,
          "SPACE(1,1) CYL REUSE"
    if rc <> 0 then do
      call say_msg 'ERROR' 'Cannot allocate output dataset' out_dsn
      /* Fall back to console                                         */
      do i = 1 to out.0
        say out.i
      end
      return
    end
  end

  "EXECIO" out.0 "DISKW OUTDD (STEM OUT. FINIS"
  execio_rc = rc
  if execio_rc <> 0 then
    call say_msg 'WARN' 'EXECIO write error — RC=' execio_rc

  "FREE FI(OUTDD)"

  address ISPEXEC

return


/*====================================================================*/
/* SAY_MSG — formatted message to console                            */
/*====================================================================*/
say_msg:
  parse arg level text
  say 'GETMSTAT' LEFT(level,5) ':' text
return


/*====================================================================*/
/* SET_MAX_RC — track the highest return code                        */
/*====================================================================*/
set_max_rc:
  parse arg newrc
  if newrc > max_rc then max_rc = newrc
return


/*====================================================================*/
/* Error / signal traps                                               */
/*====================================================================*/
bad_novalue:
  call say_msg 'ERROR' 'NOVALUE condition at line' SIGL '—' CONDITION('D')
  exit 16

bad_syntax:
  call say_msg 'ERROR' 'SYNTAX error at line' SIGL ':' ERRORTEXT(rc)
  exit 16

bad_error:
  call say_msg 'ERROR' 'ERROR condition at line' SIGL '— RC=' rc
  exit 16

         TITLE 'LMCSECTS  Load Module CSECT Scanner - Binder API'
***********************************************************************
*                                                                     *
*  LMCSECTS  -  Software Quality Dashboard ETL                       *
*                                                                     *
*  Scans load library members using the z/OS Program Management       *
*  Binder API (IEWBFB callable service) to extract CSECT-level        *
*  information and translator (IDR) data.  Writes one CSV row per     *
*  CSECT, ready for DB2 LOAD into the LOAD_MODULES extension table.  *
*                                                                     *
*  References:                                                        *
*    z/OS MVS Program Management: Advanced Facilities  SA23-1392     *
*    z/OS MVS Program Management: User Guide and Reference SA23-1391 *
*    IEWBFWA DSECT  (sys1.SHLASAMP or IBM-supplied macro library)    *
*                                                                     *
*  DD Statements:                                                     *
*    SYSLIB   - Load library (DSORG=PO, RECFM=U or DSNTYPE=LIBRARY)  *
*    SYSIN    - Module name list (FB LRECL=80)                        *
*               Col  1-8:  Member name (blank padded)                 *
*               Col  1-5 = '*ALL*': process entire library            *
*               Col  1   = '*' : comment line - skip                  *
*    SYSPRINT - Diagnostic messages (FBA LRECL=133)                  *
*    CSVOUT   - CSV output (VB LRECL=1024)                            *
*                                                                     *
*  CSV Columns (one row per CSECT):                                   *
*    MODULE_NAME, CSECT_NAME, LINK_DATE, TRANSLATOR,                  *
*    AMODE, RMODE, AUTH_CODE, REUSABLE, REENTRANT, SSID              *
*                                                                     *
*  Return Codes:                                                       *
*     0  - Success                                                     *
*     4  - Warning (one or more modules skipped)                      *
*     8  - Error (module not found, I/O error)                        *
*    12  - Severe (IEWBFB not available, open failure)               *
*                                                                     *
*  AUTHORIZATION: APF authorization NOT required.                     *
*  AMODE:         31-bit                                               *
*  RMODE:         ANY                                                  *
*                                                                     *
***********************************************************************
*
* Register Equates
*
R0       EQU   0
R1       EQU   1
R2       EQU   2                   Work
R3       EQU   3                   Work
R4       EQU   4                   CSECT table pointer
R5       EQU   5                   IDR table pointer
R6       EQU   6                   Loop counter
R7       EQU   7                   BLDL directory entry pointer
R8       EQU   8                   Binder API work area pointer
R9       EQU   9                   Module buffer pointer
R10      EQU   10                  IEWBFB entry point
R11      EQU   11                  Local base
R12      EQU   12                  Module base register
R13      EQU   13                  Save area / DSA
R14      EQU   14                  Return address
R15      EQU   15                  Entry pt / Return code
*
*----------------------------------------------------------------------
* Program Entry and Standard Linkage
*----------------------------------------------------------------------
LMCSECTS CSECT
LMCSECTS AMODE 31
LMCSECTS RMODE ANY
         SAVE  (14,12),,LMCSECTS_&SYSDATE
         LLGTR R12,R15             Establish base register (31-bit)
         USING LMCSECTS,R12
         LA    R11,WORKAREA        Second base for data areas
         USING WORKAREA,R11
         LA    R1,SAVEAREA         Point to our save area
         ST    R1,8(,R13)          Chain save areas forward
         ST    R13,4(,R1)          Chain save areas backward
         LR    R13,R1
*
*----------------------------------------------------------------------
* Initialize working storage
*----------------------------------------------------------------------
         XC    RETCODE,RETCODE     Clear overall return code
         MVC   MODCOUNT,=F'0'      Module counter
         MVC   CSCTCNT,=F'0'       CSECT counter
         MVC   SKIPCNT,=F'0'       Skipped module counter
         MVI   HDRWRIT,X'00'       CSV header not yet written
*
*----------------------------------------------------------------------
* Open SYSIN, SYSPRINT and CSVOUT
* SYSLIB is NOT opened here - IEWBFB opens it by DDNAME
*----------------------------------------------------------------------
         OPEN  (SYSIN,,SYSPRINT,OUTPUT,CSVOUT,OUTPUT)
         TM    SYSIN+DCBOFLGS-IHADCB,DCBOFOPN
         BZ    OPNERR              SYSIN failed to open
         TM    SYSPRINT+DCBOFLGS-IHADCB,DCBOFOPN
         BZ    OPNERR
         TM    CSVOUT+DCBOFLGS-IHADCB,DCBOFOPN
         BZ    OPNERR
*
*----------------------------------------------------------------------
* Load the IEWBFB callable service module
*
* IEWBFB is the z/OS Program Management Binder Fast-Path callable
* interface.  It resides in LPA (Pageable Link Pack Area) on a
* standard z/OS system and does not require explicit loading.
* However, LOAD ensures we have its current entry point.
*
* Reference: SA23-1392  Chapter "Binder callable API"
*----------------------------------------------------------------------
         LOAD  EP=IEWBFB           Load IEWBFB callable service
         LTR   R15,R15             Did LOAD succeed?
         BNZ   NOIEWBFB            No - cannot continue
         LLGTR R10,R0              Save 31-bit entry point
         ST    R10,FBEP            Store entry point for later use
*
*----------------------------------------------------------------------
* Obtain storage for the IEWBFB work area
*
* The binder API requires a private work area for session state.
* The size is defined by the IEWBFWA macro DSECT (IEWBFWLN).
* We use a generous allocation and initialize it to zeros.
*
* On your system:  COPY  IEWBFWA  to get exact IEWBFWLN equate.
* Hardcoded size below matches the work area size as of z/OS 2.5.
*----------------------------------------------------------------------
FBWKLEN  EQU   4096                IEWBFB work area length (verify!)
         GETMAIN RU,LV=FBWKLEN,LOC=BELOW
         LR    R8,R1               R8 -> IEWBFB work area
         XR    R0,R0
         LR    R1,R8
         LA    R2,FBWKLEN
         MVCL  R0,R2               Clear work area to zeros
         ST    R8,FBWKPTR          Save pointer for cleanup
*
*----------------------------------------------------------------------
* IEWBFB FUNCTION: INIT
*
* Initialize a binder API session.  Must be the first call.
* Populates the session handle in the work area.
*
* Calling convention:
*   R1  -> IEWBFB parameter block (FBPBLOCK below)
*   R10 -> IEWBFB entry point
*
* FBPBLOCK layout: see DSECT FBPBLKD below.
*   FBPFUNC  = 'INIT' (4 bytes EBCDIC)
*   FBPWKP   = address of work area
*----------------------------------------------------------------------
         MVC   FBPFUNC,=CL4'INIT'  Set function code
         ST    R8,FBPWKP           -> our work area
         XC    FBPRC,FBPRC         Clear return code
         XC    FBPRSN,FBPRSN
         LA    R1,FBPBLOCK         R1 -> parameter block
         BALR  R14,R10             Call IEWBFB
         LTR   R15,R15
         BNZ   INITERR
         L     R15,FBPRC           Check API return code
         LTR   R15,R15
         BNZ   INITERR
         L     R3,FBPHAND          Save session handle
         ST    R3,FBSHAND          Library session handle
*
*----------------------------------------------------------------------
* IEWBFB FUNCTION: LIBOPEN
*
* Open the load library (SYSLIB DD).  Must be called after INIT.
* Returns a library handle stored in the work area / parm block.
*----------------------------------------------------------------------
         MVC   FBPFUNC,=CL4'LIBO'  Function: Library Open
         MVC   FBPDDNM,=CL8'SYSLIB  ' DDNAME of load library
         XC    FBPRC,FBPRC
         XC    FBPRSN,FBPRSN
         LA    R1,FBPBLOCK
         BALR  R14,R10             Call IEWBFB
         LTR   R15,R15
         BNZ   LIBERR
         L     R15,FBPRC
         LTR   R15,R15
         BNZ   LIBERR
         L     R3,FBPHAND          Save library handle
         ST    R3,FBLHAND
*
*----------------------------------------------------------------------
* Write CSV header record to CSVOUT
*----------------------------------------------------------------------
         MVC   CSVLEN,=H'85'        Record length
         MVC   CSVDATA(83),=C'MODULE_NAME,CSECT_NAME,LINK_DATE,X
               TRANSLATOR,AMODE,RMODE,AUTH_CODE,REUSABLE,REENTRANT,X
               SSID'
         PUT   CSVOUT,CSVREC        Write CSV header
         MVI   HDRWRIT,X'FF'        Mark header written
*
*----------------------------------------------------------------------
* MAIN LOOP: Read module names from SYSIN
*----------------------------------------------------------------------
READMOD  DS    0H
         GET   SYSIN,SINBUF         Read 80-byte module name record
         B     PROCMOD              Branch to process it
*
EOFINPUT DS    0H                   End of SYSIN
         B     ALLCLOSE             Proceed to cleanup
*
PROCMOD  DS    0H
* Skip blank records
         CLC   SINBUF(8),=CL8' '    All blanks?
         BE    READMOD               Yes, skip

* Skip comment records (col 1 = '*')
         CLI   SINBUF,C'*'
         BE    READMOD

* Extract module name (cols 1–8) and store
         MVC   CURMODM,SINBUF        Copy member name
*
*----------------------------------------------------------------------
* BLDL: Get directory entry for this module
*
* The BLDL SVC (SVC 18) reads the PDS directory and returns the
* entry for the specified member.  We use it BEFORE opening the
* module with IEWBFB to extract module-level attributes from the
* directory user-data area:
*
*   Directory entry user-data layout (binder-generated, 14 halfwords):
*   +---------+------------------------------------------------------+
*   | Offset  | Content                                              |
*   +---------+------------------------------------------------------+
*   |   0- 2  | Note list TTR (3 bytes)                             |
*   |     3   | Number of notes (1 byte)                            |
*   |     4   | ATR1: X'80'=Alias X'10'=SCTR X'08'=OVLY            |
*   |         |       X'04'=TEST   X'02'=ONLY                       |
*   |     5   | ATR2: X'80'=REUS X'40'=RENT X'10'=APF(AC=1)        |
*   |         |       X'04'=AMODE31 X'02'=RMODEANY                  |
*   |   6- 7  | Module size in 8-byte blocks (halfword, binary)     |
*   |   8- 9  | Entry-point offset in 8-byte blocks                 |
*   |  10-11  | Number of RLD entries                               |
*   |  12-13  | Extended attributes (X'0001'=AMODE64, etc.)         |
*   |  14-17  | SSID — SubSystem Identifier (4 bytes, binary)       |
*   +---------+------------------------------------------------------+
*
* The C-byte (1 byte at offset +11 of each BLDL entry) contains:
*   Bit 7: alias indicator
*   Bits 4-0: number of halfwords of user data (max 31)
*----------------------------------------------------------------------
         MVC   BLDLNAME,CURMODM     Set member name in BLDL list
         MVC   BLDLLENF,=H'62'      Max user-data in entry
         BLDL  SYSLIB,BLDLLIST      Issue BLDL SVC 18
         LTR   R15,R15              BLDL return code
         BNZ   NOTFOUND             Non-zero = member not in library
*
* Parse directory entry: BLDLENTRY+8 = TTR, +11 = C byte, +12 = user data
         LA    R7,BLDLENTRY         R7 -> start of this BLDL entry
         LA    R7,12(,R7)           R7 -> start of user data
*                                   (after 8-byte name + 3-byte TTR + 1 C-byte)
*
* Extract attribute bytes from user data
         MVC   CURATM1,4(R7)        ATR1 byte (offset 4 in user data)
         MVC   CURATM2,5(R7)        ATR2 byte (offset 5 in user data)
         MVC   CURSSID,14(R7)       SSID (4 bytes at offset 14)
*
* Determine AMODE from ATR2 and extended attr
         TM    CURATM2,X'04'        AMODE(31) bit set?
         BO    SETAM31              Yes
         CLC   12(2,R7),=X'0001'    Extended attr: AMODE(64)?
         BE    SETAM64
         MVC   CURAMOD,=CL5'24   ' AMODE(24)
         B     DORMODE
SETAM31  MVC   CURAMOD,=CL5'31   ' AMODE(31)
         B     DORMODE
SETAM64  MVC   CURAMOD,=CL5'64   ' AMODE(64)
DORMODE  DS    0H
*
* Determine RMODE from ATR2
         TM    CURATM2,X'02'        RMODE(ANY)?
         BNO   RMODE24
         MVC   CURRMOD,=CL5'ANY  '
         B     DOAUTH
RMODE24  MVC   CURRMOD,=CL5'24   '
*
* Determine AUTH_CODE (AC=1 == APF authorized)
DOAUTH   DS    0H
         TM    CURATM2,X'10'        APF authorized?
         BO    SETAUTH1
         MVC   CURAUTH,=CL2'0'
         B     DOREUS
SETAUTH1 MVC   CURAUTH,=CL2'1'
*
* REUSABLE and REENTRANT flags
DOREUS   DS    0H
         TM    CURATM2,X'80'        REUS bit?
         BO    SETREUS
         MVC   CURREUS,=CL1'N'
         B     DORENT
SETREUS  MVC   CURREUS,=CL1'Y'
DORENT   DS    0H
         TM    CURATM2,X'40'        RENT bit?
         BO    SETRENT
         MVC   CURRENT,=CL1'N'
         B     CALLBIND
SETRENT  MVC   CURRENT,=CL1'Y'
*
*----------------------------------------------------------------------
* IEWBFB FUNCTION: MODOPEN (Module Open)
*
* Open the module for reading.  Passes the library handle (obtained
* from LIBOPEN) and the member name.  Returns a module handle.
*----------------------------------------------------------------------
CALLBIND DS    0H
         MVC   FBPFUNC,=CL4'MODO'   Function: Module Open
         L     R3,FBLHAND            Library handle from LIBOPEN
         ST    R3,FBPHAND
         MVC   FBPMODM,CURMODM       Member name
         XC    FBPRC,FBPRC
         XC    FBPRSN,FBPRSN
         LA    R1,FBPBLOCK
         BALR  R14,R10              Call IEWBFB
         LTR   R15,R15
         BNZ   SKIPMODS
         L     R15,FBPRC
         LTR   R15,R15
         BNZ   SKIPMODS
         L     R3,FBPMHND           Module handle
         ST    R3,FBMHAND
*
* Initialize per-module work areas
         MVC   CURLNKD,=CL10' '     Clear link date
         MVC   CURTRAN,=CL32' '     Clear translator
         MVC   CSCTIDX,=F'0'        Clear CSECT table index
         MVC   IDRIDX,=F'0'         Clear IDR table index
*
*----------------------------------------------------------------------
* IEWBFB FUNCTION: READSEG (Read Next Module Segment)
*
* Read segments from the open module one at a time.  Segments are
* returned in a caller-provided buffer pointed to by FBPBUFP.
* The type of each segment is indicated in FBPSGTP (4-byte code):
*
*   'ESDS' — ESD (External Symbol Dictionary) segment
*             Contains CSECT names and their types/attributes.
*   'IDRS' — IDR segment
*             Contains translator (compiler) identification.
*   'ATTR' — Attribute segment
*             Contains module-level attributes (supplements BLDL).
*   'MEND' — End-of-module indicator; no more segments follow.
*
* The buffer pointed to by FBPBUFP must be large enough to hold
* the segment data (FBPBLEN specifies the buffer size in bytes).
* On return, FBPSDLN contains the actual length of returned data.
*
* ESD Segment entry layout (one per ESD entry, concatenated):
*   +0   EQ  8   CSECT name (EBCDIC, blank-padded)
*   +8   EQ  1   ESD type: X'00'=SD(CSECT) X'01'=LD X'02'=ER
*                           X'04'=CM  X'06'=XD  X'07'=WX
*   +9   EQ  2   ESDID (binary halfword)
*   +11  EQ  3   Address offset within module (3 bytes, binary)
*   +14  EQ  4   Length in bytes (fullword, binary)
*   +18  EQ  4   CSECT attributes (fullword, bit flags)
*   +22  EQ  2   Entry size of this table row (halfword)
*
* IDR Segment entry layout (one per translator, concatenated):
*   +0   EQ  1   IDR entry length (binary byte)
*   +1   EQ  1   IDR type: C'1'=assembler C'2'=compiler C'B'=binder
*   +2   EQ  8   System name (EBCDIC e.g. 'z/OS    ')
*   +10  EQ  8   Translator program name (EBCDIC e.g. 'HIGH LEV')
*   +18  EQ  2   Version/release (EBCDIC e.g. '05')
*   +20  EQ  2   Minor version (EBCDIC)
*   +22  EQ  7   Date: YYYYDDD format (EBCDIC, Julian)
*   +29  EQ  6   Time: HHMMSS (EBCDIC)
*   +35  EQ  1   Reserved
*----------------------------------------------------------------------
         LA    R9,SEGBUF            Point R9 at segment buffer
         ST    R9,FBPBUFP           Store ptr in parm block
         MVC   FBPBLEN,=F'32768'   Buffer size
*
READSEG  DS    0H                   Read-segment loop
         MVC   FBPFUNC,=CL4'READ'   Function: Read Segment
         L     R3,FBMHAND
         ST    R3,FBPMHND           Pass module handle
         XC    FBPRC,FBPRC
         XC    FBPRSN,FBPRSN
         LA    R1,FBPBLOCK
         BALR  R14,R10              Call IEWBFB
         LTR   R15,R15
         BNZ   MODCLOSE             Binder error - close module
         L     R15,FBPRC
         LTR   R15,R15
         BNZ   MODCLOSE
*
* Check segment type returned in FBPSGTP
         CLC   FBPSGTP,=CL4'MEND'   End of module?
         BE    MODCLOSE
         CLC   FBPSGTP,=CL4'ESDS'   ESD segment?
         BE    PRESESD
         CLC   FBPSGTP,=CL4'IDRS'   IDR segment?
         BE    PRESIDR
         B     READSEG              Unknown type - skip
*
*----------------------------------------------------------------------
* Process ESD Segment - extract CSECT entries (type SD = X'00')
*----------------------------------------------------------------------
PRESESD  DS    0H
         L     R2,FBPSDLN           Segment data length (bytes)
         LTR   R2,R2
         BZ    READSEG              Empty segment
         LA    R4,SEGBUF            R4 -> start of ESD segment data
         LA    R3,SEGBUF            R3 = start (for boundary check)
         AR    R3,R2                R3 = end address
*
ESDLOOP  DS    0H
         CR    R4,R3                Past end of segment?
         BNL   READSEG              Yes, back to read next segment
*
*   ESD entry size is in last halfword of each entry
         LH    R6,22(,R4)           Entry size (halfword at +22)
         LTR   R6,R6               Zero entry size?
         BZ    READSEG              Malformed - skip segment
*
*   Check ESD type byte (+8): X'00' = SD (Section Definition = CSECT)
         CLI   8(R4),X'00'          SD type (CSECT start)?
         BNE   NEXTESD              Not a CSECT, skip to next entry
*
*   This is a CSECT entry - save name to CSECT table
         L     R2,CSCTIDX           Current index into CSECT table
         C     R2,=F'256'           Table full (max 256 CSECTs)?
         BNL   NEXTESD
*
         LA    R2,CSCTIDX           Index
         L     R2,CSCTIDX
         SLL   R2,3                 *8 bytes per entry
         LA    R5,CSECTTAB
         AR    R5,R2                R5 -> slot in CSECT name table
         MVC   0(8,R5),0(R4)        Store CSECT name (8 bytes)
         L     R2,CSCTIDX
         LA    R2,1(,R2)
         ST    R2,CSCTIDX           Increment index
*
NEXTESD  AR    R4,R6                Advance R4 by entry size
         B     ESDLOOP
*
*----------------------------------------------------------------------
* Process IDR Segment - extract translator (compiler) information
*
* The IDR segment contains identification records for each translation
* unit (CSECT) that was compiled/assembled.  Each IDR entry can be
* associated with a specific CSECT via sequence.  We collect the
* translator names and look for the BINDER's own IDR entry to get
* the module's link date.
*----------------------------------------------------------------------
PRESIDR  DS    0H
         L     R2,FBPSDLN           Segment data length
         LTR   R2,R2
         BZ    READSEG
         LA    R4,SEGBUF            R4 -> IDR segment data
         LA    R3,SEGBUF
         AR    R3,R2                R3 = boundary
*
IDRLOOP  DS    0H
         CR    R4,R3
         BNL   READSEG
*
         XR    R6,R6
         IC    R6,0(R4)             Entry length (byte at +0)
         LTR   R6,R6
         BZ    READSEG              Zero length - done
*
* IDR type C'B' (X'C2') = Binder IDR entry → contains link date
         CLI   1(R4),C'B'           Binder IDR?
         BE    GOTBINDR             Yes, extract link date
*
* Other IDR types - extract translator name for CSECT association.
* We save the first non-binder translator into CURTRAN.
         CLC   CURTRAN,=CL32' '     Already have a translator?
         BNE   NEXTIDRE             Yes, skip (use first found)
         MVC   IDRTMP,10(R4)        Program name at offset +10 (8 bytes)
         MVC   CURTRAN(32),IDRTMP+0 Copy up to 32 bytes of name
         B     NEXTIDRE
*
GOTBINDR DS    0H
* IDR date field at +22 (7 bytes, Julian format: YYYYDDD EBCDIC)
* Convert Julian date YYYYDDD to YYYY-MM-DD
         MVC   JULDATE(7),22(R4)    Grab YYYYDDD from IDR entry
         LA    R1,JULDATE           Convert Julian to calendar date
         LA    R2,CURLNKD
         BAL   R14,JULIAN2CAL
*
NEXTIDRE  AR   R4,R6               Advance by entry length
         AR    R4,=F'1'            Each entry preceded by length byte
         B     IDRLOOP
*
*----------------------------------------------------------------------
* MODCLOSE: Close current module and write CSV records for each CSECT
*----------------------------------------------------------------------
MODCLOSE DS    0H
         MVC   FBPFUNC,=CL4'CLSM'   Function: Close Module
         L     R3,FBMHAND
         ST    R3,FBPMHND
         XC    FBPRC,FBPRC
         LA    R1,FBPBLOCK
         BALR  R14,R10
*
* Write one CSV record per CSECT found in this module
         L     R6,CSCTIDX           Number of CSECTs found
         LTR   R6,R6
         BZ    MODDONE              No CSECTs?  Skip to next module
*
         LA    R4,CSECTTAB          R4 -> first CSECT name
CSVLOOP  DS    0H
         LTR   R6,R6               More CSECTs to write?
         BZ    MODDONE
*
         BAL   R14,BUILDCSV         Format one CSV record
         PUT   CSVOUT,CSVREC        Write to CSVOUT
*
*   Increment CSECT name pointer
         LA    R4,8(,R4)            Advance to next CSECT name
         BCTR  R6,0                 Decrement counter
         L     R2,CSCTCNT
         LA    R2,1(,R2)
         ST    R2,CSCTCNT           Total CSECT counter
         B     CSVLOOP
*
MODDONE  DS    0H
         L     R2,MODCOUNT
         LA    R2,1(,R2)
         ST    R2,MODCOUNT
         B     READMOD              Read next SYSIN record
*
*----------------------------------------------------------------------
* SKIPMODS: Module not found or open error - issue warning
*----------------------------------------------------------------------
NOTFOUND DS    0H
         PUT   SYSPRINT,MSGNOTFD
         B     SKIPMODS
SKIPMODS DS    0H
         L     R2,SKIPCNT
         LA    R2,1(,R2)
         ST    R2,SKIPCNT
         OI    RETCODE+3,X'04'      Set warning RC=4
         B     READMOD
*
*======================================================================
* ALL CLOSE: Shutdown sequence
*======================================================================
ALLCLOSE DS    0H
*
* IEWBFB: Close library
         MVC   FBPFUNC,=CL4'CLIB'
         L     R3,FBLHAND
         ST    R3,FBPHAND
         XC    FBPRC,FBPRC
         LA    R1,FBPBLOCK
         BALR  R14,R10
*
* IEWBFB: Terminate session
         MVC   FBPFUNC,=CL4'TERM'
         L     R3,FBSHAND
         ST    R3,FBPHAND
         XC    FBPRC,FBPRC
         LA    R1,FBPBLOCK
         BALR  R14,R10
*
* Free IEWBFB work area storage
         L     R1,FBWKPTR
         FREEMAIN RU,LV=FBWKLEN,A=(1)
*
* Issue summary message to SYSPRINT
         L     R2,MODCOUNT
         CVD   R2,DBLWRD
         UNPK  MSGMODC(5),DBLWRD+5(3)
         OI    MSGMODC+4,X'F0'
         L     R2,CSCTCNT
         CVD   R2,DBLWRD
         UNPK  MSGCSTC(5),DBLWRD+5(3)
         OI    MSGCSTC+4,X'F0'
         PUT   SYSPRINT,MSGSUMY
*
* Close all DCBs
         CLOSE (SYSIN,,SYSPRINT,,CSVOUT)
*
PGMEND   DS    0H
         L     R15,RETCODE
         L     R13,4(,R13)          Restore caller's save area
         RETURN (14,12),RC=(15)
*
*----------------------------------------------------------------------
* Error Exits
*----------------------------------------------------------------------
OPNERR   DS    0H
         PUT   SYSPRINT,MSGOPNER
         MVC   RETCODE,=F'12'
         B     PGMEND

NOIEWBFB DS    0H
         PUT   SYSPRINT,MSGNOAPI
         MVC   RETCODE,=F'12'
         B     PGMEND

INITERR  DS    0H
         PUT   SYSPRINT,MSGINITE
         MVC   RETCODE,=F'12'
         B     ALLCLOSE

LIBERR   DS    0H
         PUT   SYSPRINT,MSGLIBER
         MVC   RETCODE,=F'8'
         B     ALLCLOSE
*
*======================================================================
* Subroutine: BUILDCSV
*
* Formats one CSV record for the CSECT currently pointed to by R4.
* Uses module-level variables: CURMODM, CURLNKD, CURTRAN,
*                               CURAMOD, CURRMOD, CURAUTH,
*                               CURREUS, CURRENT, CURSSID.
*
* On entry: R4 -> 8-byte CSECT name in CSECT table
* Returns:  CSVREC filled, CSVLEN set
*======================================================================
BUILDCSV DS    0H
         STM   R14,R3,CSVWSAVE
         LA    R2,CSVDATA           R2 = current write position in buf
*
* Helper macro inline: append field then comma to buffer at R2
* MODULE_NAME (8 chars)
         MVC   0(8,R2),CURMODM
         LA    R2,8(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* CSECT_NAME (8 chars from R4)
         MVC   0(8,R2),0(R4)
         LA    R2,8(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* LINK_DATE (10 chars YYYY-MM-DD)
         MVC   0(10,R2),CURLNKD
         LA    R2,10(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* TRANSLATOR (up to 32 chars, blank-strip from right)
         LA    R3,31                 Find rightmost non-blank
TRBSTRIP MVC   0(1,R2),CURTRAN(R3)
         CLI   CURTRAN(R3),C' '
         BNE   TRABEND
         BCTR  R3,0
         LTR   R3,R3
         BNZ   TRBSTRIP
TRABEND  DS    0H
         MVC   0(32,R2),CURTRAN
         LA    R2,32(,R2)           (simplified: full 32-byte field)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* AMODE (5 chars)
         MVC   0(5,R2),CURAMOD
         LA    R2,5(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* RMODE (5 chars)
         MVC   0(5,R2),CURRMOD
         LA    R2,5(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* AUTH_CODE (2 chars)
         MVC   0(2,R2),CURAUTH
         LA    R2,2(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* REUSABLE (1 char Y/N)
         MVC   0(1,R2),CURREUS
         LA    R2,1(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* REENTRANT (1 char Y/N)
         MVC   0(1,R2),CURRENT
         LA    R2,1(,R2)
         MVI   0(R2),C','
         LA    R2,1(,R2)
*
* SSID (4 bytes hex printable, unpacked)
         UNPK  SSIDOUT(9),CURSSID(5) Unpack 4-byte SSID to hex print
         TR    SSIDOUT(8),HEXTAB     Translate to 0-9,A-F
         MVC   0(8,R2),SSIDOUT      Write 8-char hex SSID
         LA    R2,8(,R2)
*
* Compute record length (VB: 4-byte RDW)
         LA    R3,CSVDATA
         SR    R2,R3                R2 = data length
         AH    R2,=H'4'             Add 4 for VB RDW
         STH   R2,CSVLEN            Store in RDW LL field
         XC    CSVRES,CSVRES        Clear RDW reserved bytes
*
         LM    R14,R3,CSVWSAVE
         BR    R14
*
*======================================================================
* Subroutine: JULIAN2CAL
*
* Convert Julian date (YYYYDDD, 7 EBCDIC bytes) to calendar date
* (YYYY-MM-DD, 10 EBCDIC bytes).
*
* Entry:  R1 -> 7-byte EBCDIC Julian date (YYYYDDD)
*         R2 -> 10-byte output buffer for YYYY-MM-DD
*======================================================================
* Day-of-year table (leap and non-leap years), 12 entries each
MDAYS_NL DC    H'31,28,31,30,31,30,31,31,30,31,30,31'  Non-leap
MDAYS_LP DC    H'31,29,31,30,31,30,31,31,30,31,30,31'  Leap year
*
JULIAN2CAL DS  0H
         STM   R14,R9,JUL2SAVE
*
*  Get 4-digit year
         PACK  DBLWRD(8),0(4,R1)    Pack YYYY chars
         CVB   R3,DBLWRD            R3 = year
*
*  Get 3-digit Julian day
         PACK  DBLWRD(8),4(3,R1)
         CVB   R4,DBLWRD            R4 = Julian Day
*
*  Determine if leap year (R3=year, result in R9: 1=leap, 0=not)
         XR    R9,R9                Assume not leap
         LR    R5,R3
         SRDA  R5,32
         D     R5,=F'4'
         LTR   R5,R5                Divisible by 4?
         BNZ   NOTLEAP
         LR    R5,R3
         SRDA  R5,32
         D     R5,=F'100'
         LTR   R5,R5                Divisible by 100?
         BNZ   ISLEAP
         LR    R5,R3
         SRDA  R5,32
         D     R5,=F'400'
         LTR   R5,R5                Divisible by 400?
         BNZ   NOTLEAP
ISLEAP   LA    R9,1                 It IS a leap year
         B     CHKMONTH
NOTLEAP  XR    R9,R9
*
CHKMONTH DS    0H
*  Walk month table to find month number
         LA    R6,1                 Month counter starting at 1
         LTR   R9,R9               Leap year?
         BNZ   USELEAP
         LA    R7,MDAYS_NL         -> non-leap table
         B     MONLOOP
USELEAP  LA    R7,MDAYS_LP
*
MONLOOP  CH    R4,0(,R7)           Day <= days in this month?
         BNH   FOUNDMON
         SH    R4,0(,R7)           Subtract month's days
         LA    R6,1(,R6)           Next month
         LA    R7,2(,R7)           Advance table ptr
         C     R6,=F'13'           Past December?
         BL    MONLOOP
*  Shouldn't happen with valid input; clamp to December
         LA    R6,12
FOUNDMON DS    0H                  R6=month (1-12), R4=day-of-month
*
*  Format YYYY-MM-DD into output buffer at R2
         CVD   R3,DBLWRD           Year
         UNPK  0(5,R2),DBLWRD+5(3)
         OI    3(R2),X'F0'
         MVI   4(R2),C'-'
         CVD   R6,DBLWRD           Month
         UNPK  5(3,R2),DBLWRD+6(2)
         OI    6(R2),X'F0'
         MVI   7(R2),C'-'
         CVD   R4,DBLWRD           Day
         UNPK  8(3,R2),DBLWRD+6(2)
         OI    9(R2),X'F0'
*
         LM    R14,R9,JUL2SAVE
         BR    R14
*
*======================================================================
* IEWBFB Parameter Block DSECT
*
* This parameter block is passed (via R1) on every IEWBFB call.
*
* IMPORTANT:  The exact field offsets below are based on the IBM
*             IEWBFB callable API documentation as of z/OS 2.5.
*             On your system, issue:  COPY  IEWBFWA
*             in an assembler source to get the authoritative DSECT.
*             Adjust any discrepancies before assembly.
*======================================================================
FBPBLKD  DSECT                      IEWBFB parameter block
FBPEYEC  DS    CL4                   Eye-catcher: 'FBAP'
FBPVER   DS    F                     API version: X'00000001'
FBPFUNC  DS    CL4                   Function code (4-char EBCDIC):
*                                     'INIT' Initialize session
*                                     'LIBO' Open library (SYSLIB)
*                                     'MODO' Open module
*                                     'READ' Read next segment
*                                     'CLSM' Close module
*                                     'CLIB' Close library
*                                     'TERM' Terminate session
FBPRC    DS    F                     Return code (set by IEWBFB)
FBPRSN   DS    F                     Reason code (set by IEWBFB)
FBPHAND  DS    F                     In/Out: session/library handle
FBPMHND  DS    F                     In/Out: module handle
FBPDDNM  DS    CL8                   Library DDNAME (function LIBO)
FBPMODM  DS    CL8                   Module name (function MODO)
FBPFLG1  DS    XL4                   Processing flags
FBPBUFP  DS    A                     Pointer to segment data buffer
FBPBLEN  DS    F                     In: segment buffer size (bytes)
FBPSDLN  DS    F                     Out: segment data length
FBPSGTP  DS    CL4                   Out: segment type returned
*                                     'ESDS' ESD segment
*                                     'IDRS' IDR segment
*                                     'ATTR' Attribute segment
*                                     'MEND' End of module
FBPBLKL  EQU  *-FBPBLKD             Length of parameter block
*
*======================================================================
* Working Storage / Data Areas
*======================================================================
WORKAREA DSECT
SAVEAREA DS    18F                   Register save area
RETCODE  DS    F                     Program return code
MODCOUNT DS    F                     Modules processed
CSCTCNT  DS    F                     Total CSECTs written
SKIPCNT  DS    F                     Modules skipped
HDRWRIT  DS    X                     X'FF'=CSV header written
DBLWRD   DS    D                     Work doubleword
CSVWSAVE DS    4F                    BUILDCSV save area
JUL2SAVE DS    9F                    JULIAN2CAL save area
*
* Binder API session handles and entry point
FBEP     DS    A                     IEWBFB entry point
FBWKPTR  DS    A                     Ptr to IEWBFB work area
FBSHAND  DS    F                     Session handle (from INIT)
FBLHAND  DS    F                     Library handle (from LIBOPEN)
FBMHAND  DS    F                     Module handle (from MODOPEN)
*
* IEWBFB parameter block instance
FBPBLOCK DS    0F                    Align to fullword
         ORG   FBPBLOCK
FBPBLKI  DS    XL(FBPBLKL)          Parameter block instance
*
* Per-module extracted attributes (from BLDL directory and IDR)
CURMODM  DS    CL8                   Current module name
CURATM1  DS    XL1                   ATR1 from directory
CURATM2  DS    XL1                   ATR2 from directory
CURLNKD  DS    CL10                  Link date YYYY-MM-DD
CURTRAN  DS    CL32                  Translator name/version
CURAMOD  DS    CL5                   AMODE: '24','31','64','ANY'
CURRMOD  DS    CL5                   RMODE: '24','ANY'
CURAUTH  DS    CL2                   AUTH_CODE: '0' or '1'
CURREUS  DS    CL1                   REUSABLE: 'Y' or 'N'
CURRENT  DS    CL1                   REENTRANT: 'Y' or 'N'
CURSSID  DS    XL4                   SSID (4-byte binary)
SSIDOUT  DS    CL9                   SSID unpacked (8 hex + spare)
CSCTIDX  DS    F                     CSECT table index (count)
IDRIDX   DS    F                     IDR table index
IDRTMP   DS    CL8                   IDR temporary work
JULDATE  DS    CL7                   Julian date work area
*
* BLDL parameter list
BLDLLIST DS    0F
BLDLNUM  DC    H'1'                  1 entry in list
BLDLLENF DC    H'62'                 Entry length (max user-data)
BLDLENTRY DS   0CL74                 One BLDL entry (8+3+1+62)
BLDLNAME DS    CL8                   Member name
BLDLTTR  DS    CL3                   TTR (set by BLDL)
BLDLCBYT DS    CL1                   C byte (alias+halfwords)
BLDLUDAT DS    CL62                  User data (max 31 halfwords)
*
* CSECT name table (max 256 CSECT names, 8 bytes each)
CSECTTAB DS    256CL8                CSECT name table
*
* Segment data buffer (for IEWBFB READ function)
SEGBUF   DS    CL32768               32K segment buffer
*
* Hex translation table for SSID formatting
HEXTAB   DC    C'0123456789ABCDEF'
*
* SYSIN buffer
SINBUF   DS    CL80
*
* CSVOUT record (VB format: 4-byte RDW + data)
CSVREC   DS    0F
CSVLEN   DS    H                     VB record length (incl. RDW)
CSVRES   DS    H                     RDW reserved (must be 0)
CSVDATA  DS    CL1020               CSV data area
*
*----------------------------------------------------------------------
* Message constants
*----------------------------------------------------------------------
MSGOPNER DC    C'LMCS001E  Could not open one or more required DDnames.'
         DC    50C' '
         DS    0H
MSGNOAPI DC    C'LMCS002E  IEWBFB not found. Verify Load Library setup.'
         DC    47C' '
         DS    0H
MSGINITE DC    C'LMCS003E  IEWBFB INIT function failed.               '
         DC    48C' '
         DS    0H
MSGLIBER DC    C'LMCS004E  IEWBFB LIBOPEN failed for SYSLIB.          '
         DC    47C' '
         DS    0H
MSGNOTFD DC    C'LMCS005W  Module not found in SYSLIB - skipped.      '
         DC    47C' '
         DS    0H
MSGSUMY  DS    0CL133
         DC    C'LMCS006I  Modules processed: '
MSGMODC  DC    C'     '
         DC    C'  CSECTs written: '
MSGCSTC  DC    C'     '
         DC    74C' '
*
*======================================================================
* DCB Definitions
*======================================================================
SYSLIB   DCB   DSORG=PO,MACRF=R,DDNAME=SYSLIB,EODAD=EOFINPUT,        X
               DCBE=SYSLBDCB
SYSLBDCB DCBE  RMODE31=BUFF
*
SYSIN    DCB   DSORG=PS,MACRF=GM,DDNAME=SYSIN,LRECL=80,RECFM=FB,     X
               EODAD=EOFINPUT,DCBE=SINEDCB
SINEDCB  DCBE  RMODE31=BUFF
*
SYSPRINT DCB   DSORG=PS,MACRF=PM,DDNAME=SYSPRINT,LRECL=133,RECFM=FBA,X
               DCBE=SPRNTDCB
SPRNTDCB DCBE  RMODE31=BUFF
*
CSVOUT   DCB   DSORG=PS,MACRF=PM,DDNAME=CSVOUT,LRECL=1024,RECFM=VB,  X
               DCBE=CSVDCB
CSVDCB   DCBE  RMODE31=BUFF
*
         LTORG
*
         IHADCB  DSECT=YES           Map DCB for flag testing
         DCBD    DSORG=PS,DEVD=DA    DCB DSECT
         END   LMCSECTS

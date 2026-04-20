//LMCSECTS JOB (ACCT),'CSECT SCANNER',CLASS=A,MSGCLASS=H,
//             MSGLEVEL=(1,1),NOTIFY=&SYSUID
//*==================================================================*
//* LMCSECTS - Assemble, Link-edit, and Execute                       *
//*==================================================================*
//* Step 1: Assemble LMCSECTS                                         *
//*==================================================================*
//ASM      EXEC PGM=ASMA90,
//             PARM='OBJECT,NODECK,XREF(SHORT),LIST'
//SYSLIB   DD  DSN=SYS1.MACLIB,DISP=SHR
//         DD  DSN=SYS1.MODGEN,DISP=SHR
//*        DD  DSN=your.SHLASAMP,DISP=SHR     <- add if you COPY IEWBFWA
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(2,1))
//SYSPRINT DD  SYSOUT=*
//SYSPUNCH DD  DUMMY
//SYSLIN   DD  DSN=&&OBJ,DISP=(NEW,PASS),
//             UNIT=SYSDA,SPACE=(TRK,(5,2))
//SYSIN    DD  DSN=your.HLASM.LIB(LMCSECTS),DISP=SHR
//*==================================================================*
//* Step 2: Link-edit                                                  *
//*==================================================================*
//LKED     EXEC PGM=IEWL,COND=(4,LT,ASM),
//             PARM='REUS,RENT,XREF,LIST,AMOD=31,RMOD=ANY'
//SYSLIB   DD  DSN=CEE.SCEELKED,DISP=SHR
//         DD  DSN=SYS1.LINKLIB,DISP=SHR
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSPRINT DD  SYSOUT=*
//SYSLMOD  DD  DSN=your.LOADLIB(LMCSECTS),DISP=SHR
//SYSLIN   DD  DSN=&&OBJ,DISP=(OLD,DELETE)
//*==================================================================*
//* Step 3: Execute LMCSECTS                                           *
//*==================================================================*
//RUN      EXEC PGM=LMCSECTS,COND=(4,LT,LKED)
//STEPLIB  DD  DSN=your.LOADLIB,DISP=SHR
//*
//SYSLIB   DD  DSN=your.TARGET.LOADLIB,DISP=SHR   <- library to scan
//*
//SYSIN    DD  *
IEFBR14
IEFSD075
IEAVNIP
*
* Or use '*ALL*   ' to scan the entire library:
*ALL*
//*
//SYSPRINT DD  SYSOUT=*
//*
//CSVOUT   DD  DSN=your.HLQ.CSECTS.CSV,
//             DISP=(NEW,CATLG,DELETE),
//             SPACE=(CYL,(1,1),RLSE),
//             DCB=(DSORG=PS,RECFM=VB,LRECL=1024,BLKSIZE=0)
//*

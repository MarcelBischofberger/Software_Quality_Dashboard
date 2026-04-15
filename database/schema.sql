-- ==============================================================================
-- Mainframe Software Quality Dashboard DB2 Schema
-- ==============================================================================

-- ==============================================================================
-- 1. ENVIRONMENTS TABLE
-- ==============================================================================
CREATE TABLE ENVIRONMENTS (
    ENV_ID          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ENV_NAME        VARCHAR(50) NOT NULL,
    SYSPLEX_NAME    VARCHAR(50) NOT NULL,
    DESCRIPTION     VARCHAR(255),
    CREATED_AT      TIMESTAMP DEFAULT CURRENT TIMESTAMP
);

-- ==============================================================================
-- 2. DATASETS TABLE (PDS / PDS/E)
-- ==============================================================================
-- Maximum MVS dataset name length is 44 characters.
-- This table captures a comprehensive set of dataset allocation and SMS attributes.
CREATE TABLE DATASETS (
    DS_ID               INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ENV_ID              INTEGER NOT NULL,
    DATASET_NAME        VARCHAR(44) NOT NULL,
    
    -- Core Attributes
    VOLUME_SERIAL       VARCHAR(6),   -- VOLSER
    DEVICE_TYPE         VARCHAR(10),  -- E.g., '3390', 'SYSDA'
    DSORG               VARCHAR(4),   -- 'PO' or 'PO-E'
    RECFM               VARCHAR(5),   -- 'FB', 'VB', 'U', etc.
    LRECL               INTEGER,      
    BLKSIZE             INTEGER,      
    DSNTYPE             VARCHAR(10),  -- 'PDS', 'LIBRARY', etc.
    
    -- Space Attributes
    SPACE_UNIT          VARCHAR(10),  -- 'TRK', 'CYL', 'BLK'
    SPACE_PRIMARY       INTEGER,      -- Primary quantity
    SPACE_SECONDARY     INTEGER,      -- Secondary quantity
    DIR_BLOCKS          INTEGER,      -- Directory blocks (largely for standard PDS, but relevant info)
    EXTENTS_ALLOCATED   SMALLINT,     -- Number of volumes or extents
    PERCENT_USED        SMALLINT,     -- Percentage of used space
    
    -- SMS Attributes
    DATACLAS            VARCHAR(8),   -- Data Class
    STORCLAS            VARCHAR(8),   -- Storage Class
    MGMTCLAS            VARCHAR(8),   -- Management Class
    
    -- Dates
    CREATION_DATE       DATE,
    EXPIRATION_DATE     DATE,
    
    RECORDED_AT         TIMESTAMP DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT FK_DATASET_ENV FOREIGN KEY (ENV_ID) 
        REFERENCES ENVIRONMENTS(ENV_ID) ON DELETE CASCADE,
    CONSTRAINT UQ_DATASET_ENV UNIQUE (DATASET_NAME, ENV_ID)
);

-- ==============================================================================
-- 3. SOURCE_MEMBERS TABLE (With ISPF Stats)
-- ==============================================================================
-- Attributes associated with standard PDS/E source code members
CREATE TABLE SOURCE_MEMBERS (
    MEMBER_ID       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    DS_ID           INTEGER NOT NULL,
    MEMBER_NAME     VARCHAR(8) NOT NULL,
    
    -- ISPF Statistics
    VERSION_NUM     SMALLINT,     -- VV
    MOD_LEVEL       SMALLINT,     -- MM
    CREATION_DATE   DATE,         -- Created
    LAST_MOD_DATE   DATE,         -- Changed Date
    LAST_MOD_TIME   TIME,         -- Changed Time
    CURRENT_LINES   INTEGER,      -- Size
    INITIAL_LINES   INTEGER,      -- Init
    MODIFIED_LINES  INTEGER,      -- Mod
    USERID          VARCHAR(8),   -- ID (User who last modified)
    
    RECORDED_AT     TIMESTAMP DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT FK_SRC_DATASET FOREIGN KEY (DS_ID) 
        REFERENCES DATASETS(DS_ID) ON DELETE CASCADE,
    CONSTRAINT UQ_SRC_MEMBER_DS UNIQUE (MEMBER_NAME, DS_ID)
);

-- ==============================================================================
-- 4. LOAD_MODULES TABLE
-- ==============================================================================
-- Attributes associated with compiled load modules (typically RECFM=U)
CREATE TABLE LOAD_MODULES (
    MEMBER_ID       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    DS_ID           INTEGER NOT NULL,
    MEMBER_NAME     VARCHAR(8) NOT NULL,
    
    -- Binder/Linkage Editor Statistics
    ALIAS_INDICATOR CHAR(1),      -- 'Y' if this is an alias, 'N' if primary
    ALIAS_OF        VARCHAR(8),   -- The primary member name if this is an alias
    MODULE_SIZE     INTEGER,      -- Size of module in bytes/hex
    AMODE           VARCHAR(5),   -- Addressing Mode (e.g., '24', '31', '64', 'ANY')
    RMODE           VARCHAR(5),   -- Residency Mode (e.g., '24', 'ANY')
    AUTH_CODE       SMALLINT,     -- AC (Authorization Code)
    LINK_DATE       DATE,         -- Link-edit Date
    LINK_TIME       TIME,         -- Link-edit Time
    ENTRY_POINT     VARCHAR(8),   -- Main entry point
    RECORDED_AT     TIMESTAMP DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT FK_LOAD_DATASET FOREIGN KEY (DS_ID) 
        REFERENCES DATASETS(DS_ID) ON DELETE CASCADE,
    CONSTRAINT UQ_LOAD_MEMBER_DS UNIQUE (MEMBER_NAME, DS_ID)
);

-- ==============================================================================
-- 5. VOLUMES TABLE
-- ==============================================================================
-- Records DASD volume space and VTOC metrics
CREATE TABLE VOLUMES (
    VOL_ID              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ENV_ID              INTEGER NOT NULL,
    VOLSER              VARCHAR(6) NOT NULL,
    
    -- Status and properties
    DEVICE_TYPE         VARCHAR(10),  -- e.g., '3390'
    SMS_MANAGED         CHAR(1),      -- 'Y' or 'N'
    STORAGE_GROUP       VARCHAR(8),   -- SMS storage group name
    
    -- Capacity and Space
    TOTAL_CAPACITY_MB   INTEGER,      -- Total capacity in MB
    FREE_SPACE_MB       INTEGER,      -- Total free space in MB
    FREE_SPACE_TRK      INTEGER,      -- Total free space in Tracks
    FREE_SPACE_CYL      INTEGER,      -- Total free space in Cylinders
    FREE_EXTENTS        INTEGER,      -- Number of free space extents
    LARGEST_FREE_EXT_CYL INTEGER,     -- Largest free extent in Cylinders
    LARGEST_FREE_EXT_TRK INTEGER,     -- Largest free extent in Tracks
    PERCENT_FREE        DECIMAL(5,2), -- % of free space
    FRAGMENTATION_INDEX INTEGER,      -- Fragmentation index
    
    RECORDED_AT         TIMESTAMP DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT FK_VOLUME_ENV FOREIGN KEY (ENV_ID) 
        REFERENCES ENVIRONMENTS(ENV_ID) ON DELETE CASCADE,
    CONSTRAINT UQ_VOLSER_ENV UNIQUE (VOLSER, ENV_ID)
);

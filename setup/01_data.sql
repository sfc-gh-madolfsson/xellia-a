/* =====================================================================
   Xellia — CORTEX CODE BUILDATHON · Track A (AI Agents)
   SYNTHETIC DATA  (repo file 01)  —  run AFTER 00_provision.sql
   ---------------------------------------------------------------------
   Creates database XELLIA_AGENTS (RAW / ANALYTICS / APP) and the data
   your "Key Account Copilot" reasons over:
     structured  : CUSTOMER_MASTER, ORDER_LINES (~3M), TERRITORY_PERFORMANCE,
                   ACCOUNT_TARGETING
     unstructured: FIELD_NOTES (account call notes, technical inquiries,
                   tender and contract notes) — the text the agent explains with

   Deliberate messiness is planted (tagged "INCONSISTENCY:") so you must
   govern PII and standardize values while building. All objects are
   FULLY QUALIFIED. A LARGE generation warehouse is used, then dropped.
   Idempotent: CREATE OR REPLACE.

   Synthetic data. Customer names, contacts and figures are invented.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;   -- or your admin-like role

-- Fast, disposable generation warehouse (dropped at the end)
CREATE OR REPLACE WAREHOUSE XELLIA_GEN_WH
  WAREHOUSE_SIZE = 'LARGE' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = FALSE;
USE WAREHOUSE XELLIA_GEN_WH;

-- Lab warehouse (created here too so 01 is safe to run standalone)
CREATE WAREHOUSE IF NOT EXISTS XELLIA_AGENTS_WH
  WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = FALSE;

CREATE DATABASE IF NOT EXISTS XELLIA_AGENTS;
CREATE SCHEMA IF NOT EXISTS XELLIA_AGENTS.RAW;
CREATE SCHEMA IF NOT EXISTS XELLIA_AGENTS.ANALYTICS;
CREATE SCHEMA IF NOT EXISTS XELLIA_AGENTS.APP;

/* =====================================================================
   CUSTOMER_MASTER (50,000 + 500 duplicates) — account profile + contact PII
   Accounts are manufacturers, distributors, wholesalers and hospital
   pharmacies that buy APIs and finished dosage forms.
   INCONSISTENCY: ~2% null contact names; 500 duplicate CUSTOMER_IDs;
                  country + tier drift
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.CUSTOMER_MASTER AS
SELECT
  'CUST_' || LPAD(SEQ4()::string, 6, '0')                                 AS CUSTOMER_ID,
  GET(ARRAY_CONSTRUCT('Nordhaven Pharma A/S','Baltica Generics AB','Rhein Pharma GmbH',
      'Iberia Farma SL','Adriatic Labs d.o.o.','Lakeside Hospital Group','Meridian Wholesale Ltd',
      'Sakura Pharma KK','Ganges Life Sciences Pvt Ltd','Cascade Compounding Inc',
      'Helvetia Sterile AG','Atlas Distribution BV'), UNIFORM(0,11,RANDOM()))::string AS CUSTOMER_NAME,
  GET(ARRAY_CONSTRUCT('Generic Manufacturer','Innovator Pharma','Distributor','Wholesaler',
      'Hospital Pharmacy','CDMO Partner','Compounding Pharmacy'), UNIFORM(0,6,RANDOM()))::string AS ACCOUNT_TYPE,
  -- PII: named individual at the customer
  CASE WHEN UNIFORM(1,100,RANDOM()) <= 2 THEN NULL
       ELSE GET(ARRAY_CONSTRUCT('Anne Sorensen','Lars Bruun','Katrin Weber','Miguel Torres',
              'Sofia Berg','Johan Andersson','Karin Holm','Peter Madsen','Elin Lund',
              'Rajesh Nair','Yuki Tanaka','David Miller'),
              UNIFORM(0,11,RANDOM()))::string END                         AS PRIMARY_CONTACT_NAME,
  LOWER('contact' || SEQ4() || '@example-pharma.com')                     AS PRIMARY_CONTACT_EMAIL,  -- PII
  GET(ARRAY_CONSTRUCT('Procurement Lead','QA Manager','Supply Chain Planner',
      'Regulatory Affairs','Head of Sourcing','Hospital Pharmacist'), UNIFORM(0,5,RANDOM()))::string AS CONTACT_ROLE,
  -- INCONSISTENCY: same country written many ways
  GET(ARRAY_CONSTRUCT('Denmark','denmark','DK','Danmark','Germany','germany','DE','Deutschland',
      'United States','usa','US','U.S.A.'), UNIFORM(0,11,RANDOM()))::string AS COUNTRY,
  'TERR_' || LPAD(UNIFORM(1,200,RANDOM())::string, 3, '0')                AS TERRITORY_ID,
  -- INCONSISTENCY: tier label drift
  GET(ARRAY_CONSTRUCT('A','Tier 1','tier1','1','B','Tier 2','tier2','2','C','Tier 3'),
      UNIFORM(0,9,RANDOM()))::string                                     AS ACCOUNT_TIER,
  DATEADD('day', -UNIFORM(0,1800,RANDOM()), CURRENT_DATE())              AS ONBOARDED_DATE
FROM TABLE(GENERATOR(ROWCOUNT => 50000));

-- INCONSISTENCY: 500 duplicate CUSTOMER_ID rows (breaks uniqueness)
INSERT INTO XELLIA_AGENTS.RAW.CUSTOMER_MASTER
SELECT * FROM XELLIA_AGENTS.RAW.CUSTOMER_MASTER
WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM XELLIA_AGENTS.RAW.CUSTOMER_MASTER ORDER BY CUSTOMER_ID LIMIT 500);

/* =====================================================================
   ORDER_LINES (~3,000,000) — fact: what was ordered, by whom, when, how much
   INCONSISTENCY: ~2% null CUSTOMER_ID; ~1% negative QUANTITY_UNITS;
                  ~3% orphan customer; product case drift
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.ORDER_LINES AS
SELECT
  'OL_' || LPAD(SEQ4()::string, 10, '0')                                 AS ORDER_LINE_ID,
  CASE
    WHEN UNIFORM(1,100,RANDOM()) <= 2 THEN NULL
    WHEN UNIFORM(1,100,RANDOM()) <= 3 THEN 'CUST_' || LPAD(UNIFORM(900000,999999,RANDOM())::string,6,'0')
    ELSE 'CUST_' || LPAD(UNIFORM(0,49999,RANDOM())::string, 6, '0')
  END                                                                    AS CUSTOMER_ID,
  GET(ARRAY_CONSTRUCT('Vancomycin','vancomycin','Colistimethate Sodium','colistimethate sodium',
      'Polymyxin B','Daptomycin','Teicoplanin','Bacitracin','Amphotericin B','Caspofungin',
      'Micafungin','Tobramycin','Gentamicin','Neomycin'), UNIFORM(0,13,RANDOM()))::string AS PRODUCT,
  GET(ARRAY_CONSTRUCT('API','Finished Dosage Form','Ready-to-Use Premix'), UNIFORM(0,2,RANDOM()))::string AS PRODUCT_FORM,
  DATEADD('day', -UNIFORM(0,730,RANDOM()), CURRENT_DATE())               AS ORDER_DATE,
  CASE WHEN UNIFORM(1,100,RANDOM()) <= 1 THEN -1 * UNIFORM(1,5,RANDOM())
       ELSE UNIFORM(1,60,RANDOM()) END                                   AS QUANTITY_UNITS,
  ROUND(UNIFORM(400,90000,RANDOM()) + UNIFORM(0,99,RANDOM())/100.0, 2)    AS ORDER_VALUE_EUR
FROM TABLE(GENERATOR(ROWCOUNT => 3000000));

/* =====================================================================
   TERRITORY_PERFORMANCE (200)  — INCONSISTENCY: ~5% market share > 1
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.TERRITORY_PERFORMANCE AS
SELECT
  'TERR_' || LPAD(SEQ4()::string, 3, '0')                                AS TERRITORY_ID,
  GET(ARRAY_CONSTRUCT('Nordics','DACH','Southern Europe','UK and Ireland','North America',
      'Latin America','Middle East and Africa','Asia Pacific'), UNIFORM(0,7,RANDOM()))::string AS REGION,
  UNIFORM(500, 40000, RANDOM())                                          AS ADDRESSABLE_DEMAND_KG,
  CASE WHEN UNIFORM(1,100,RANDOM()) <= 5 THEN ROUND(UNIFORM(101,140,RANDOM())/100.0, 3)
       ELSE ROUND(UNIFORM(5,85,RANDOM())/100.0, 3) END                   AS MARKET_SHARE,
  UNIFORM(1, 12, RANDOM())                                               AS ACTIVE_ACCOUNT_MANAGERS,
  DATE_TRUNC('quarter', CURRENT_DATE())                                  AS REPORT_QUARTER
FROM TABLE(GENERATOR(ROWCOUNT => 200));

/* =====================================================================
   ACCOUNT_TARGETING (50,000) — INCONSISTENCY: priority case drift;
                                tiers differ from CUSTOMER_MASTER
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.ACCOUNT_TARGETING AS
SELECT
  'CUST_' || LPAD(SEQ4()::string, 6, '0')                                 AS CUSTOMER_ID,
  GET(ARRAY_CONSTRUCT('High','Medium','Low','HIGH','med','LOW'), UNIFORM(0,5,RANDOM()))::string AS PRIORITY,
  GET(ARRAY_CONSTRUCT('Tier 1','Tier 2','Tier 3'), UNIFORM(0,2,RANDOM()))::string AS ACCOUNT_TIER,
  UNIFORM(0,100,RANDOM())                                                AS DIGITAL_ENGAGEMENT_SCORE,
  (UNIFORM(0,1,RANDOM()) = 1)                                            AS SUPPLY_CRITICAL_ACCOUNT,
  (UNIFORM(0,1,RANDOM()) = 1)                                            AS TENDER_ACTIVE
FROM TABLE(GENERATOR(ROWCOUNT => 50000));

/* =====================================================================
   FIELD_NOTES (40,000) — UNSTRUCTURED text (Cortex Search source)
   Doc types: Account Call Note / Technical Inquiry / Tender and Contract Note
   INCONSISTENCY: ~2% empty text; ~3% blank customer reference
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.FIELD_NOTES AS
SELECT
  'NOTE_' || LPAD(SEQ4()::string, 7, '0')                                AS NOTE_ID,
  GET(ARRAY_CONSTRUCT('Account Call Note','Technical Inquiry','Tender and Contract Note'), UNIFORM(0,2,RANDOM()))::string AS DOC_TYPE,
  CASE WHEN UNIFORM(1,100,RANDOM()) <= 3 THEN NULL
       ELSE 'CUST_' || LPAD(UNIFORM(0,49999,RANDOM())::string, 6, '0') END AS CUSTOMER_ID,
  GET(ARRAY_CONSTRUCT('Nordics','DACH','Southern Europe','UK and Ireland','North America',
      'Latin America','Middle East and Africa','Asia Pacific'), UNIFORM(0,7,RANDOM()))::string AS REGION,
  DATEADD('day', -UNIFORM(0,540,RANDOM()), CURRENT_DATE())               AS NOTE_DATE,
  CASE WHEN UNIFORM(1,100,RANDOM()) <= 2 THEN NULL ELSE
    GET(ARRAY_CONSTRUCT(
      'Customer raised concerns about lead times on vancomycin API; asked whether we can reserve capacity ahead of their next campaign.',
      'Discussed qualification of us as a second source for colistimethate; customer wants the drug master file reference and stability data.',
      'Tender note: national hospital tender for daptomycin closes next quarter; price pressure from Asian API suppliers is the main risk.',
      'Technical inquiry regarding elemental impurity limits and the latest pharmacopoeia monograph update for polymyxin B.',
      'Customer reports strong demand growth in their sterile injectables line but cites allocation concerns affecting their launch plan.',
      'Competitive pressure noted: a competitor is offering aggressive multi-year pricing; customer asked for a firm supply commitment instead.',
      'Supply continuity discussion: customer wants dual-site release and a safety stock agreement written into the contract.',
      'Quality note: customer requested an updated certificate of analysis format and asked about our change control notification timelines.',
      'Positive feedback on our GMP audit outcome; customer open to expanding the portfolio to teicoplanin and bacitracin.',
      'Inquiry about ready-to-use premix presentations and whether hospital compounding volumes could shift to a finished product.',
      'Nordics region: strong uptake with hospital groups but the wholesaler channel lags; requested joint account planning.',
      'Customer paused new volumes pending their own regulatory variation approval; asked to be re-contacted after the next review cycle.',
      'Reported a stockout at a regional distributor; concerned about hospitals switching to an alternative supplier and not switching back.',
      'Enthusiastic about antimicrobial resistance stewardship data; would consider a joint scientific symposium with their medical team.'
    ), UNIFORM(0,13,RANDOM()))::string END                               AS NOTE_TEXT
FROM TABLE(GENERATOR(ROWCOUNT => 40000));

/* =====================================================================
   PROFILE — confirm tables + total rows
   ===================================================================== */
SELECT 'CUSTOMER_MASTER' AS tbl, COUNT(*) AS row_count FROM XELLIA_AGENTS.RAW.CUSTOMER_MASTER
UNION ALL SELECT 'ORDER_LINES', COUNT(*) FROM XELLIA_AGENTS.RAW.ORDER_LINES
UNION ALL SELECT 'TERRITORY_PERFORMANCE', COUNT(*) FROM XELLIA_AGENTS.RAW.TERRITORY_PERFORMANCE
UNION ALL SELECT 'ACCOUNT_TARGETING', COUNT(*) FROM XELLIA_AGENTS.RAW.ACCOUNT_TARGETING
UNION ALL SELECT 'FIELD_NOTES', COUNT(*) FROM XELLIA_AGENTS.RAW.FIELD_NOTES
ORDER BY row_count DESC;

-- Tidy up: drop the disposable generation warehouse, leave the MEDIUM lab warehouse.
USE WAREHOUSE XELLIA_AGENTS_WH;
DROP WAREHOUSE IF EXISTS XELLIA_GEN_WH;

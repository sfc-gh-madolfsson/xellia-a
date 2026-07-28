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
   Each note is composed from several interchangeable fragments (opening,
   issue, ask, next step) plus a product, site, contact role and market, so
   the 40,000 notes are almost all distinct rather than a handful of strings
   repeated thousands of times. That matters: a search service can only rank
   and an agent can only cite if the text actually varies.
   INCONSISTENCY: ~2% empty text; ~3% blank customer reference
   ===================================================================== */
CREATE OR REPLACE TABLE XELLIA_AGENTS.RAW.FIELD_NOTES AS
WITH base AS (
  SELECT
    'NOTE_' || LPAD(SEQ4()::string, 7, '0')                              AS NOTE_ID,
    GET(ARRAY_CONSTRUCT('Account Call Note','Technical Inquiry','Tender and Contract Note'),
        UNIFORM(0,2,RANDOM()))::string                                   AS DOC_TYPE,
    CASE WHEN UNIFORM(1,100,RANDOM()) <= 3 THEN NULL
         ELSE 'CUST_' || LPAD(UNIFORM(0,49999,RANDOM())::string, 6, '0') END AS CUSTOMER_ID,
    GET(ARRAY_CONSTRUCT('Nordics','DACH','Southern Europe','UK and Ireland','North America',
        'Latin America','Middle East and Africa','Asia Pacific'), UNIFORM(0,7,RANDOM()))::string AS REGION,
    DATEADD('day', -UNIFORM(0,540,RANDOM()), CURRENT_DATE())             AS NOTE_DATE,
    -- the product the note is about, so the notes can be searched and filtered by product
    GET(ARRAY_CONSTRUCT('vancomycin','colistimethate sodium','polymyxin B','daptomycin',
        'teicoplanin','bacitracin','amphotericin B','caspofungin','micafungin','tobramycin',
        'gentamicin','neomycin','vancomycin ready-to-use premix','colistimethate injection'),
        UNIFORM(0,13,RANDOM()))::string                                  AS PRODUCT,
    GET(ARRAY_CONSTRUCT('Copenhagen','Oslo','Budapest','Zagreb','Cleveland'),
        UNIFORM(0,4,RANDOM()))::string                                   AS SITE,
    GET(ARRAY_CONSTRUCT('their procurement lead','their QA manager','their supply chain planner',
        'their regulatory affairs contact','their head of sourcing','their technical operations lead'),
        UNIFORM(0,5,RANDOM()))::string                                   AS CONTACT_ROLE,
    GET(ARRAY_CONSTRUCT('a generic manufacturer','a hospital group','a regional distributor',
        'a wholesaler','a CDMO partner'), UNIFORM(0,4,RANDOM()))::string  AS ACCOUNT_CONTEXT
  FROM TABLE(GENERATOR(ROWCOUNT => 40000))
)
SELECT
  NOTE_ID, DOC_TYPE, CUSTOMER_ID, PRODUCT, REGION, NOTE_DATE,
  CASE
    WHEN UNIFORM(1,100,RANDOM()) <= 2 THEN NULL
    /* ---------------- Account Call Note ---------------- */
    WHEN DOC_TYPE = 'Account Call Note' THEN
      'Call with ' || CONTACT_ROLE || ' at ' || ACCOUNT_CONTEXT || ' in ' || REGION || '. '
      || GET(ARRAY_CONSTRUCT(
           'Reviewed the rolling forecast for ' || PRODUCT || '.',
           'Went through open orders and lead times for ' || PRODUCT || '.',
           'Quarterly business review, focused on ' || PRODUCT || '.',
           'Follow-up call after their site visit; ' || PRODUCT || ' was the main topic.',
           'Introductory call with a new contact; portfolio discussion centred on ' || PRODUCT || '.',
           'Called to confirm the delivery schedule for ' || PRODUCT || '.',
           'Check-in ahead of their production campaign for ' || PRODUCT || '.',
           'Annual contract renewal discussion covering ' || PRODUCT || '.',
           'Escalation call following a late delivery of ' || PRODUCT || '.',
           'Joint account planning session; ' || PRODUCT || ' volumes reviewed in detail.',
           'Called about their expansion into new markets with ' || PRODUCT || '.',
           'Debrief after the audit; commercial impact on ' || PRODUCT || ' discussed.'
         ), UNIFORM(0,11,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'They flagged that lead times slipped to ' || UNIFORM(4,16,RANDOM())::string || ' weeks on recent shipments.',
           'Volumes are tracking about ' || UNIFORM(5,35,RANDOM())::string || ' percent below their committed forecast.',
           'They are carrying only ' || UNIFORM(2,8,RANDOM())::string || ' weeks of safety stock and are uncomfortable with it.',
           'Their own launch has been delayed, so they want to reschedule Q' || UNIFORM(1,4,RANDOM())::string || ' volumes.',
           'They raised a pricing gap of roughly ' || UNIFORM(3,18,RANDOM())::string || ' percent against a competing offer.',
           'A short shipment last quarter forced them to allocate internally.',
           'They have started qualifying a second source and were candid about it.',
           'Demand in their home market has grown faster than their forecast allowed for.',
           'They are frustrated that change control notifications arrive late.',
           'Their finance team is pushing for payment terms of ' || UNIFORM(30,120,RANDOM())::string || ' days.',
           'A competing supplier has offered a multi-year price hold they find attractive.',
           'They see hospital tenders moving toward ready-to-use presentations.',
           'Regulatory approval in one market slipped, stalling planned volumes.',
           'Consolidation on their side means the account will be re-tendered next year.'
         ), UNIFORM(0,13,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'They asked for a firm capacity reservation ahead of the next campaign.',
           'They want dual-site release written into the contract.',
           'They requested a safety stock agreement held at our expense.',
           'They asked for an indicative price for a ' || UNIFORM(2,5,RANDOM())::string || ' year commitment.',
           'They want a written supply continuity statement for their own customers.',
           'They asked whether we can shorten lead times if volumes are committed earlier.',
           'They requested a joint forecasting process with monthly reviews.',
           'They asked for the drug master file reference to support their filing.',
           'They want to visit the ' || SITE || ' site before increasing volumes.',
           'They asked for support material on antimicrobial resistance stewardship.',
           'They requested a sample batch for their formulation work.',
           'They asked to be introduced to our technical team directly.'
         ), UNIFORM(0,11,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'Agreed to come back with a written proposal before month end.',
           'Action: share the updated allocation plan this week.',
           'Next step is a joint call with supply planning.',
           'Agreed to revisit once their regulatory approval lands.',
           'I will confirm available capacity from the ' || SITE || ' site.',
           'Follow-up scheduled for the next planning cycle.',
           'Passed the technical questions to regulatory affairs.',
           'Agreed to hold current pricing while we review the volume commitment.',
           'Escalated internally; commercial director to be involved.',
           'No action agreed yet; they will come back after their board review.'
         ), UNIFORM(0,9,RANDOM()))::string
    /* ---------------- Technical Inquiry ---------------- */
    WHEN DOC_TYPE = 'Technical Inquiry' THEN
      GET(ARRAY_CONSTRUCT(
           'Question on elemental impurity limits for ' || PRODUCT || '.',
           'Query on the latest pharmacopoeia monograph revision affecting ' || PRODUCT || '.',
           'Request for stability data on ' || PRODUCT || ' under accelerated conditions.',
           'Clarification requested on the residual solvent specification for ' || PRODUCT || '.',
           'Question about the particle size distribution of ' || PRODUCT || '.',
           'Query on endotoxin limits for ' || PRODUCT || '.',
           'Request for the extractables and leachables package for ' || PRODUCT || '.',
           'Question on nitrosamine risk assessment for ' || PRODUCT || '.',
           'Clarification on the sterility assurance approach for ' || PRODUCT || '.',
           'Query on container closure compatibility for ' || PRODUCT || '.',
           'Request for comparative dissolution data for ' || PRODUCT || '.',
           'Question on the shelf life claim for ' || PRODUCT || '.'
         ), UNIFORM(0,11,RANDOM()))::string || ' Raised by ' || CONTACT_ROLE || ' at '
      || ACCOUNT_CONTEXT || ' in ' || REGION || '. '
      || GET(ARRAY_CONSTRUCT(
           'Their analytical team measured a result near the upper specification limit.',
           'The question came out of a regulatory query in one of their markets.',
           'They are preparing a variation filing and need supporting documentation.',
           'Their contract laboratory used a different method and got a different answer.',
           'This follows a customer complaint they are investigating.',
           'They are transferring the method to a new site.',
           'Their reviewer asked for justification of the specification range.',
           'The query relates to a new market with stricter requirements.',
           'They are comparing our data against a competitor certificate of analysis.',
           'Their stability programme flagged a trend they want explained.',
           'This came up during their annual product quality review.',
           'They are qualifying a new packaging configuration.'
         ), UNIFORM(0,11,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'They asked for a formal written response for their file.',
           'They requested a call with our analytical development team.',
           'They asked for the method validation report.',
           'They requested an updated certificate of analysis format.',
           'They asked whether the specification can be tightened.',
           'They want confirmation that no change has been made to the process.',
           'They asked for historical batch data to support a trend analysis.',
           'They requested a regulatory support letter.',
           'They asked for guidance on handling and storage.',
           'They want to know the notification timeline for any future change.'
         ), UNIFORM(0,9,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'Response due within ' || UNIFORM(5,20,RANDOM())::string || ' working days.',
           'Routed to regulatory affairs for a formal answer.',
           'Answered on the call; documentation to follow.',
           'Open; awaiting input from the ' || SITE || ' site.',
           'Closed once the data package was sent.',
           'Escalated because their filing deadline is tight.',
           'Pending; they owe us their method details first.',
           'Answered, but they may come back after their internal review.'
         ), UNIFORM(0,7,RANDOM()))::string
    /* ---------------- Tender and Contract Note ---------------- */
    ELSE
      GET(ARRAY_CONSTRUCT(
           'National hospital tender for ' || PRODUCT || ' closes next quarter.',
           'Regional purchasing group is re-tendering ' || PRODUCT || '.',
           'Framework agreement for ' || PRODUCT || ' is up for renewal.',
           'Public tender for ' || PRODUCT || ' published with a short response window.',
           'Group purchasing organisation has consolidated ' || PRODUCT || ' into a single lot.',
           'Two-year supply contract for ' || PRODUCT || ' out for bid.',
           'Tender for ' || PRODUCT || ' reopened after the first round was annulled.',
           'Hospital network is standardising on a single supplier for ' || PRODUCT || '.',
           'Ministry tender for ' || PRODUCT || ' expected to be published shortly.',
           'Existing contract for ' || PRODUCT || ' extended by ' || UNIFORM(3,12,RANDOM())::string || ' months.',
           'Distributor is bidding for ' || PRODUCT || ' and has asked us to back them.',
           'Tender for ' || PRODUCT || ' now requires a ready-to-use presentation.'
         ), UNIFORM(0,11,RANDOM()))::string || ' Market: ' || REGION || ', via ' || ACCOUNT_CONTEXT || '. '
      || GET(ARRAY_CONSTRUCT(
           'Price pressure is significant; the incumbent is roughly ' || UNIFORM(4,22,RANDOM())::string || ' percent below our indicative level.',
           'Award is on lowest price, with a supply reliability threshold to pass.',
           'They are weighting supply continuity at ' || UNIFORM(20,40,RANDOM())::string || ' percent of the score.',
           'A multi-year price hold is expected as a condition.',
           'Volumes are indicative only, with no minimum commitment.',
           'Payment terms of ' || UNIFORM(30,120,RANDOM())::string || ' days are specified and non-negotiable.',
           'Award will be split across two suppliers to reduce risk.',
           'Penalties for late delivery are written into the draft contract.',
           'They require a fixed price in local currency for the full term.',
           'Evaluation includes a documented dual-site capability.',
           'The specification favours European manufacture, which helps us.',
           'Local warehousing is required, which affects our cost base.'
         ), UNIFORM(0,11,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'Asian API suppliers are expected to bid aggressively.',
           'The incumbent has held this contract for ' || UNIFORM(2,9,RANDOM())::string || ' years.',
           'Two competitors have already confirmed they will bid.',
           'A local distributor is bidding with a competitor product.',
           'We are the only supplier with European production in scope.',
           'The incumbent has had supply failures, which is our opening.',
           'A new entrant has been qualified since the last round.',
           'Competition is limited; few suppliers meet the specification.',
           'The incumbent is rumoured to be exiting the molecule.',
           'Pricing from the last round is public and sets expectations.'
         ), UNIFORM(0,9,RANDOM()))::string || ' '
      || GET(ARRAY_CONSTRUCT(
           'Bid or no-bid decision needed within ' || UNIFORM(1,6,RANDOM())::string || ' weeks.',
           'Pricing proposal in preparation with commercial finance.',
           'Decision taken to bid; documentation being assembled.',
           'Recommend we decline unless capacity frees up.',
           'Awaiting clarification questions from the buyer.',
           'Distributor agreement needs signing before we can respond.',
           'Legal reviewing the penalty clauses before we commit.',
           'Awaiting internal approval on the price floor.',
           'Site confirmation needed from ' || SITE || ' before bidding.',
           'Outcome expected ' || UNIFORM(1,5,RANDOM())::string || ' months after submission.'
         ), UNIFORM(0,9,RANDOM()))::string
  END                                                                    AS NOTE_TEXT
FROM base;

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

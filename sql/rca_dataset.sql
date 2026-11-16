-- ############################################################################
--
--  Causal validation of action rules for root cause analysis in psychiatric
--  care: cohort, event log and admission attributes
--  SAP HANA, OMOP CDM.
--
--  This script builds every table the pipeline needs, from the OMOP tables
--  only. The pipeline reads three exports (see THE EXPORTS):
--    event_log_sample.csv     drug, condition and procedure events per stay
--    rca_adm_features.csv     one row per stay: outcome, process and severity
--                             attributes
--    rca_adm_drug_timing.csv  first and last day of each antidepressant
--
--  BEFORE YOU RUN
--    work_schema stands for a schema you can write to. Replace it everywhere
--    with the name of your own schema. Every table this script makes goes
--    there. Until you replace it, HANA stops with "invalid schema name".
--    cdmphi is the OMOP CDM schema at Mount Sinai. If your OMOP schema has
--    another name, replace cdmphi too.
--    The script reads only OMOP tables in cdmphi (concept, concept_ancestor,
--    person, death, visit_occurrence, condition_occurrence, drug_exposure,
--    procedure_occurrence, observation, measurement) and tables it builds
--    itself, always after building them. DUMMY is the HANA system table.
--
--  COLUMNS THAT ARE NOT STANDARD OMOP
--    The Mount Sinai Data Warehouse (MSDW) adds columns to its OMOP tables.
--    Other OMOP instances may not have them:
--      drug_exposure.xtn_pharmaceutical_class_source_concept_name
--        the pharmacy class of the drug record
--    MSDW also stores the concept name next to the concept id on some tables
--    (condition_concept_name, drug_concept_name, procedure_concept_name,
--    visit_concept_name). In standard OMOP, these come from a join to concept.
--
--  DEFINITIONS
--    Cohort          adults (18 to 120 years) with a first MDD diagnosis
--                    between 1 January 2011 and 30 June 2026, at least one
--                    visit in the year before it, and no bipolar disorder,
--                    schizophrenia or schizoaffective disorder on or before
--                    it. MDD is a set of 107 SNOMED concepts (Part 1).
--                    Follow-up ends at the window end, a later competing
--                    diagnosis, or death.
--    Stay            an Inpatient Visit (9201) or an Emergency Room and
--                    Inpatient Visit (262) with an MDD diagnosis, inside
--                    follow-up, with a valid discharge date. A visit that
--                    starts inside an earlier one is merged into it.
--    Readmission     any inpatient visit (9201 or 262) of the same person
--                    that starts 3 to 30 days after the discharge day. All
--                    causes. Days 0 to 2 are left out, because these are
--                    often transfers, as in the CMS psychiatric measure.
--    In analysis     the 30 days after discharge lie inside the window, so
--                    the outcome is fully observed.
--    Antidepressant  SSRIs, SNRIs, tricyclics, MAOIs and atypicals. No
--                    augmentation drugs, no esketamine, no orders. A record
--                    belongs to the stay when it is linked to the admission
--                    visit or dated inside the stay.
--
--  ATTRIBUTES OF EACH STAY
--    Process, from the order and timing of antidepressants:
--      first_ad_day       day of the first antidepressant record, counted
--                         from the admission day (day 0)
--      ad_timing          none, early (first record on day 0 or 1), late
--      ad_switch          1 if one antidepressant was stopped and another
--                         started later in the same stay
--      n_ad_ingredients   number of different antidepressants in the stay
--      is_first_admission 1 for the person's first stay in the cohort
--      admission_no       the person's stays counted in date order
--    Severity at admission:
--      ed_arrival         the stay came through the emergency department:
--                         visit type 262, or an ED visit (9203 or 262) on
--                         the admission day or the day before
--      ideation_dx        a suicidal ideation record from the day before
--                         admission to discharge
--      attempt_dx         a suicide attempt record (also a history of one)
--                         in the same window
--      The C-SSRS screening is not used: in this OMOP instance it exists only
--      for outpatient visits (Part 8). Involuntary admission is not recorded.
--    Death:
--      died_by_day30      death between admission and day 30 after discharge
--
--  HOW TO RUN
--    Run the blocks top to bottom. Checks marked "must return zero rows" must
--    return nothing. If one returns rows, stop and fix it before going on.
--    Part 8 is only needed to look at the suicide risk records in detail.
--    To run the script again, first run the CLEAN-UP blocks at the end. They
--    drop every table this script makes, in reverse order.
--
--  PRIVACY
--    Patient data never leaves Mount Sinai. Only this code and aggregate
--    results are shared. The summaries hide cells under 11.
--
-- ############################################################################



-- ############################################################################
-- PART 1.  PARAMETERS AND CONCEPT SETS
-- ############################################################################


-- The study window and the minimum age, in one place. June 2026 is the last
-- month with full data in all domains.
--@block
CREATE TABLE work_schema.rca_params AS (
    SELECT
        CAST('2011-01-01' AS DATE) AS window_start,
        CAST('2026-06-30' AS DATE) AS window_end,
        18   AS min_age_at_index
    FROM DUMMY
);

-- The antidepressant and augmentation ingredients, with their class.
-- Later, class "Augmentation" becomes AUG_RX, class "Others" becomes
-- INTERVENTIONAL_RX (esketamine), and everything else becomes AD_RX.
-- Only AD_RX enters the event log. Racemic ketamine is listed here, but I
-- remove it in rca_ad_raw.
--@block
CREATE TABLE work_schema.rca_ad_ingredients AS (
    WITH mapping AS (
        SELECT 797617 AS concept_id, 'Citalopram' AS ancestor_concept_name, 'SSRI' AS category FROM DUMMY UNION ALL
        SELECT 19010886, 'Clopenthixol/zuclopenthixol', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 715259,   'duloxetine', 'SNRIs' FROM DUMMY UNION ALL
        SELECT 739138,   'Sertraline', 'SSRI' FROM DUMMY UNION ALL
        SELECT 715939,   'Escitalopram', 'SSRI' FROM DUMMY UNION ALL
        SELECT 755695,   'Fluoxetine', 'SSRI' FROM DUMMY UNION ALL
        SELECT 751412,   'Fluvoxamine', 'SSRI' FROM DUMMY UNION ALL
        SELECT 714684,   'Nefazodone', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 722031,   'Paroxetine', 'SSRI' FROM DUMMY UNION ALL
        SELECT 743670,   'venlafaxine', 'SNRIs' FROM DUMMY UNION ALL
        SELECT 717607,   'desvenlafaxine', 'SNRIs' FROM DUMMY UNION ALL
        SELECT 43560354, 'levomilnacipran', 'SNRIs' FROM DUMMY UNION ALL
        SELECT 19080226, 'milnacipran', 'SNRIs' FROM DUMMY UNION ALL
        SELECT 703547,   'trazodone', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 725131,   'mirtazapine', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 44507700, 'vortioxetine', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 40234834, 'vilazodone', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 750982,   'bupropion', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 36878783, 'agomelatine', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 19084693, 'reboxetine', 'Atypical Antidepressants' FROM DUMMY UNION ALL
        SELECT 778268,   'imipramine', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 721724,   'nortriptyline', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 710062,   'amitriptyline', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 738156,   'doxepin', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 716968,   'desipramine', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 754270,   'protriptyline', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 705755,   'trimipramine', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 794147,   'maprotiline', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 713109,   'amoxapine', 'Tricyclic Antidepressants' FROM DUMMY UNION ALL
        SELECT 703470,   'tranylcypromine', 'MAOIs' FROM DUMMY UNION ALL
        SELECT 733896,   'phenelzine', 'MAOIs' FROM DUMMY UNION ALL
        SELECT 781705,   'isocarboxazid', 'MAOIs' FROM DUMMY UNION ALL
        SELECT 766209,   'selegiline', 'MAOIs' FROM DUMMY UNION ALL
        SELECT 19010652, 'moclobemide', 'MAOIs' FROM DUMMY UNION ALL
        SELECT 757688,   'aripiprazole', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 766814,   'quetiapine', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 19124477, 'lithium', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 19017241, 'iloperidone', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 1366610,  'esketamine', 'Others' FROM DUMMY UNION ALL
        select 36848877, 'clopenthixol', 'Augmentation' FROM DUMMY UNION ALL
        SELECT 785649,   'ketamine', 'Others' FROM DUMMY
    )
    SELECT
        ancestor_concept_name AS ANCESTOR_CONCEPT_NAME,
        category AS CATEGORY,
        concept_id AS CONCEPT_ID
    FROM mapping
);

-- All standard, valid RxNorm drug concepts under those ingredients.
--@block
CREATE TABLE work_schema.rca_ad_concepts AS (
    SELECT DISTINCT
        al.concept_id              AS ancestor_concept_id,
        al.ancestor_concept_name   AS ancestor_concept_name,
        ca.descendant_concept_id,
        al.category                AS category,
        cp.concept_name            AS descendant_concept_name,
        cp.concept_class_id        AS descendant_concept_class_id,
        cp.vocabulary_id           AS descendant_vocabulary_id
    FROM cdmphi.concept_ancestor AS ca
    INNER JOIN work_schema.rca_ad_ingredients AS al
        ON ca.ancestor_concept_id = al.concept_id
    INNER JOIN cdmphi.concept AS cp
        ON ca.descendant_concept_id = cp.concept_id
    WHERE cp.vocabulary_id = 'RxNorm'
      AND cp.standard_concept = 'S'
      AND cp.invalid_reason IS NULL
);

-- The 22 SNOMED depression concepts I start the MDD phenotype from.
--@block
CREATE TABLE work_schema.rca_mdd_source_ancestors AS (
    SELECT
        cpt.concept_id       as ancestor_concept_id,
        cpt.concept_code     as ancestor_concept_code,
        cpt.concept_class_id as ancestor_concept_class_id,
        cpt.vocabulary_id    as vocabulary_id,
        cpt.concept_name     as ancestor_concept_name
    FROM cdmphi.concept as cpt
    WHERE cpt.concept_id IN (
                '432883', '433440', '433991', '434911', '435220', '435520',
                '438406', '438727', '438998', '440383', '441534', '4025677',
                '4049623', '4077577', '4098302', '4141454', '4195572',
                '4228802', '4263748', '4282096', '4282316', '4323418'
            )
            AND cpt.vocabulary_id = 'SNOMED'
);

-- All standard, valid condition concepts under those 22 ancestors, minus a
-- curated list of codes that are not MDD. The next blocks refine this set.
--@block
CREATE TABLE work_schema.rca_mdd_source_concepts AS (
    SELECT DISTINCT
        cail.ancestor_concept_id,
        cail.ancestor_concept_name,
        cpt_rel.descendant_concept_id,
        cpt.concept_name              AS descendant_concept_name,
        cpt.concept_class_id          AS descendant_concept_class_id,
        cpt.vocabulary_id             AS descendant_vocabulary_id
    FROM cdmphi.concept_ancestor AS cpt_rel
    INNER JOIN work_schema.rca_mdd_source_ancestors AS cail
        ON cail.ancestor_concept_id = cpt_rel.ancestor_concept_id
    INNER JOIN cdmphi.concept AS cpt
        ON cpt.concept_id = cpt_rel.descendant_concept_id
    WHERE cpt.standard_concept = 'S'          -- standard concepts only
      AND cpt.domain_id        = 'Condition'  -- guard against cross-domain descendants
      AND cpt.invalid_reason IS NULL          -- exclude deprecated concepts
      AND cpt_rel.descendant_concept_id NOT IN (
            439254, 4224940, 437528, 439253, 35622934, 439251, 4107538, 4332994, 37109952,
            443864, 4336980, 4333687, 40481798, 4133073, 4338031, 4038252, 4242733, 4145216,
            42538584, 42538590, 42538596, 42538599, 42538601, 42538604, 42538736, 4103126,
            44782720, 44782720, 37164792, 37117211, 37110438, 37110428, 37110438, 3654788,
            37209503, 37309680, 37110429, 37109950, 4092239
      )
);

-- Depression codes I take OUT of the MDD phenotype:
--   peripartum, depression with a medical cause (postviral, postoperative,
--   menopausal), below-threshold codes (minor, brief recurrent, minimal),
--   non-specific phrases, and, by exact name, adjustment disorder, induced
--   mood disorders and other non-MDD conditions.
-- I keep dysthymia and persistent depressive disorder IN, on purpose. I also
-- keep psychotic depression, DSM specifiers, remission states and reactive
-- depression. Minimal recurrent, masked and involutional depression stay in too.
--@block
CREATE TABLE work_schema.rca_mdd_exclusion_ancestors AS (


    SELECT 4093584 AS concept_id, 'PERIPARTUM' AS exclusion_class, 'enumerated' AS resolution FROM DUMMY
    UNION ALL SELECT 4239471,  'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 4129184,  'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 4129842,  'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 4324959,  'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 42534817, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 36712668, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 37312479, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 44806193, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 37018656, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 45757195, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 45757196, 'PERIPARTUM', 'enumerated' FROM DUMMY
    UNION ALL SELECT 45757213, 'PERIPARTUM', 'enumerated' FROM DUMMY

    UNION ALL SELECT 4102973,  'MEDICAL_ATTRIBUTION', 'enumerated' FROM DUMMY  -- Postviral depression
    UNION ALL SELECT 4305966,  'MEDICAL_ATTRIBUTION', 'enumerated' FROM DUMMY  -- Postoperative depression
    UNION ALL SELECT 4223090,  'MEDICAL_ATTRIBUTION', 'enumerated' FROM DUMMY  -- Menopausal depression
    UNION ALL SELECT 37166876, 'MEDICAL_ATTRIBUTION', 'enumerated' FROM DUMMY  -- Postmenopausal depression

    UNION ALL SELECT 4174987,  'SUBTHRESHOLD', 'enumerated' FROM DUMMY  -- Minor depressive disorder
    UNION ALL SELECT 4226155,  'SUBTHRESHOLD', 'enumerated' FROM DUMMY  -- Recurrent brief depressive disorder
    UNION ALL SELECT 36713698, 'SUBTHRESHOLD', 'enumerated' FROM DUMMY  -- Minimal depression

    UNION ALL SELECT 4131545,  'NONSPECIFIC', 'enumerated' FROM DUMMY  -- Depression requiring intervention
    UNION ALL SELECT 37016718, 'NONSPECIFIC', 'enumerated' FROM DUMMY  -- Acute depression


    UNION ALL
    SELECT c.concept_id, n.exclusion_class, 'name_resolved'
    FROM cdmphi.concept c
    JOIN (
              SELECT 'PERIPARTUM'         AS exclusion_class, 'POSTPARTUM DEPRESSION'          AS nm FROM DUMMY
    UNION ALL SELECT 'PERIPARTUM',        'POSTNATAL DEPRESSION'                                   FROM DUMMY
    UNION ALL SELECT 'PERIPARTUM',        'DEPRESSION IN THE PUERPERIUM'                           FROM DUMMY
    UNION ALL SELECT 'ADJUSTMENT',        'ADJUSTMENT DISORDER'                                    FROM DUMMY
    UNION ALL SELECT 'ADJUSTMENT',        'ADJUSTMENT DISORDER WITH DEPRESSED MOOD'                FROM DUMMY
    UNION ALL SELECT 'ADJUSTMENT',        'ADJUSTMENT DISORDER WITH MIXED ANXIETY AND DEPRESSED MOOD' FROM DUMMY
    UNION ALL SELECT 'ADJUSTMENT',        'PROLONGED DEPRESSIVE REACTION'                          FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'SUBSTANCE-INDUCED MOOD DISORDER'                        FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'DRUG-INDUCED DEPRESSIVE STATE'                          FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'ALCOHOL-INDUCED MOOD DISORDER'                          FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'MOOD DISORDER DUE TO A GENERAL MEDICAL CONDITION'       FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'DEPRESSIVE DISORDER DUE TO A GENERAL MEDICAL CONDITION' FROM DUMMY
    UNION ALL SELECT 'INDUCED',           'ORGANIC MOOD DISORDER'                                  FROM DUMMY
    UNION ALL SELECT 'UNSPECIFIED_NONMDD','SEASONAL AFFECTIVE DISORDER'                            FROM DUMMY
    UNION ALL SELECT 'UNSPECIFIED_NONMDD','PREMENSTRUAL DYSPHORIC DISORDER'                        FROM DUMMY
    UNION ALL SELECT 'UNSPECIFIED_NONMDD','DISRUPTIVE MOOD DYSREGULATION DISORDER'                 FROM DUMMY
    UNION ALL SELECT 'UNSPECIFIED_NONMDD','MIXED ANXIETY AND DEPRESSIVE DISORDER'                  FROM DUMMY
    UNION ALL SELECT 'UNSPECIFIED_NONMDD','BEREAVEMENT'                                            FROM DUMMY
    ) n
      ON UPPER(c.concept_name) = n.nm
    WHERE c.vocabulary_id    = 'SNOMED'
      AND c.domain_id        = 'Condition'
      AND c.standard_concept = 'S'
      AND c.invalid_reason IS NULL
);

-- Dysthymia and persistent depressive disorder. I use this list as a guard, so
-- the curated list of non-MDD codes cannot remove them.
--@block
CREATE TABLE work_schema.rca_mdd_retained_ancestors AS (
              SELECT 607543  AS concept_id, 'PERSISTENT_DEPRESSIVE_DISORDER' AS retention_class FROM DUMMY
    UNION ALL SELECT 433440,  'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4057218, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4096229, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4150047, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4195680, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4224639, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4243308, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4263770, 'DYSTHYMIA' FROM DUMMY
    UNION ALL SELECT 4307951, 'DYSTHYMIA' FROM DUMMY
);

-- The excluded ancestors from above, expanded to all their descendants, plus
-- the curated list of non-MDD codes (minus anything under dysthymia or PDD).
--@block
CREATE TABLE work_schema.rca_mdd_excluded_concepts AS (
    SELECT DISTINCT
        ca.descendant_concept_id AS concept_id,
        cp.concept_name,
        cp.vocabulary_id,
        cp.concept_class_id,
        MIN(a.exclusion_class) AS exclusion_class,
        CAST('descendant_of_excluded_ancestor' AS NVARCHAR(60)) AS exclusion_reason
    FROM work_schema.rca_mdd_exclusion_ancestors a
    JOIN cdmphi.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
    JOIN cdmphi.concept cp          ON cp.concept_id = ca.descendant_concept_id
    WHERE cp.domain_id = 'Condition'
      AND cp.invalid_reason IS NULL
    GROUP BY ca.descendant_concept_id, cp.concept_name, cp.vocabulary_id, cp.concept_class_id

    UNION ALL

    SELECT DISTINCT
        cp.concept_id, cp.concept_name, cp.vocabulary_id, cp.concept_class_id,
        CAST('CURATED' AS NVARCHAR(30)),
        CAST('curated_not_mdd' AS NVARCHAR(60))
    FROM cdmphi.concept cp
    WHERE cp.concept_id IN (
            439254, 4224940, 437528, 439253, 35622934, 439251, 4107538, 4332994, 37109952,
            443864, 4336980, 4333687, 40481798, 4133073, 4338031, 4038252, 4242733, 4145216,
            42538584, 42538590, 42538596, 42538599, 42538601, 42538604, 42538736, 4103126,
            44782720, 37164792, 37117211, 37110438, 37110428, 3654788,
            37209503, 37309680, 37110429, 37109950, 4092239
          )
      AND NOT EXISTS (
            SELECT 1
            FROM cdmphi.concept_ancestor ca2
            JOIN work_schema.rca_mdd_retained_ancestors r
              ON r.concept_id = ca2.ancestor_concept_id
            WHERE ca2.descendant_concept_id = cp.concept_id)
);

-- The final MDD phenotype: the source set minus every excluded concept.
-- On my run this gave 107 concepts.
--@block
CREATE TABLE work_schema.rca_mdd_concepts AS (
    SELECT DISTINCT
        d.descendant_concept_id       AS concept_id,
        d.descendant_concept_name     AS concept_name,
        d.descendant_concept_class_id AS concept_class_id,
        d.descendant_vocabulary_id    AS vocabulary_id,
        d.ancestor_concept_id,
        d.ancestor_concept_name
    FROM work_schema.rca_mdd_source_concepts d
    WHERE NOT EXISTS (SELECT 1 FROM work_schema.rca_mdd_excluded_concepts x
                      WHERE x.concept_id = d.descendant_concept_id)
);

-- Competing psychiatric diagnoses: bipolar disorder, mania, hypomania,
-- cyclothymia, schizophrenia and schizoaffective disorder.
--@block
CREATE TABLE work_schema.rca_psych_exclusion_ancestors AS (
    SELECT c.concept_id, n.exclusion_class, c.concept_name, c.concept_code
    FROM cdmphi.concept c
    JOIN (
              SELECT 'BIPOLAR'         AS exclusion_class, 'BIPOLAR DISORDER' AS nm FROM DUMMY
    UNION ALL SELECT 'BIPOLAR',        'MANIC DISORDER'                            FROM DUMMY
    UNION ALL SELECT 'BIPOLAR',        'MANIA'                                     FROM DUMMY
    UNION ALL SELECT 'BIPOLAR',        'HYPOMANIA'                                 FROM DUMMY
    UNION ALL SELECT 'BIPOLAR',        'CYCLOTHYMIC DISORDER'                      FROM DUMMY
    UNION ALL SELECT 'SCHIZOPHRENIA',  'SCHIZOPHRENIA'                             FROM DUMMY
    UNION ALL SELECT 'SCHIZOAFFECTIVE','SCHIZOAFFECTIVE DISORDER'                  FROM DUMMY
    ) n
      ON UPPER(c.concept_name) = n.nm
    WHERE c.vocabulary_id    = 'SNOMED'
      AND c.domain_id        = 'Condition'
      AND c.standard_concept = 'S'
      AND c.invalid_reason IS NULL
);

-- Those psychiatric ancestors expanded to all their descendants.
--@block
CREATE TABLE work_schema.rca_psych_exclusion_concepts AS (
    SELECT DISTINCT
        ca.descendant_concept_id AS concept_id,
        cp.concept_name,
        cp.vocabulary_id,
        MIN(a.exclusion_class) AS exclusion_class
    FROM work_schema.rca_psych_exclusion_ancestors a
    JOIN cdmphi.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
    JOIN cdmphi.concept cp          ON cp.concept_id = ca.descendant_concept_id
    WHERE cp.domain_id = 'Condition'
      AND cp.invalid_reason IS NULL
    GROUP BY ca.descendant_concept_id, cp.concept_name, cp.vocabulary_id
);

-- Must return zero rows. No concept may be both MDD and a competing diagnosis.
--@block
SELECT m.concept_id, m.concept_name, p.exclusion_class
FROM work_schema.rca_mdd_concepts m
JOIN work_schema.rca_psych_exclusion_concepts p ON p.concept_id = m.concept_id;

-- Must return zero rows. No dysthymia or PDD concept may still be excluded.
--@block
SELECT x.concept_id, x.concept_name, x.exclusion_class, x.exclusion_reason
FROM work_schema.rca_mdd_excluded_concepts x
WHERE x.concept_id IN (SELECT concept_id FROM work_schema.rca_mdd_retained_ancestors)
   OR EXISTS (SELECT 1
              FROM cdmphi.concept_ancestor ca
              JOIN work_schema.rca_mdd_retained_ancestors r
                ON r.concept_id = ca.ancestor_concept_id
              WHERE ca.descendant_concept_id = x.concept_id);

-- Every concept, standard or not, with "suicid" or "C-SSRS" in its name, and
-- its group. A record counts when its standard concept OR its source concept
-- is in this set. Matching on the source concept matters: the C-SSRS
-- screening is stored in Epic flowsheet rows (vocabulary EPIC FLO), and some
-- of them map to a standard concept without "suicide" in its name, or to
-- none at all (for example "R HH SUICIDE 1").
--   C-SSRS     the Columbia Suicide Severity Rating Scale, a short yes/no
--              suicide screening
--   flowsheet  the Epic form where nurses enter answers like these
-- The five Athena concepts I started from (601899, 37208165, 44807820,
-- 44809512, 4021336) are covered by the name search too. They are almost
-- unused at Mount Sinai.
-- Groups, from rules on the concept name, tested in this order:
--   SCREENING       a flowsheet or LOINC item (vocabulary EPIC FLO or LOINC)
--   FAMILY_HISTORY  "family" or "relative" in the name. Not about the patient.
--   ATTEMPT         "attempt" in the name
--   IDEATION        "ideation" or "suicidal thought" in the name
--   RISK            "risk" in the name
--   OTHER           everything else
-- "sr" in the table names means suicide risk.
--@block
CREATE TABLE work_schema.rca_sr_concept_set AS (
    SELECT
        c.concept_id,
        c.concept_name,
        c.vocabulary_id,
        c.domain_id,
        c.concept_class_id,
        c.standard_concept,
        CAST(CASE
            WHEN c.vocabulary_id LIKE 'EPIC FLO%'
              OR c.vocabulary_id = 'LOINC'                      THEN 'SCREENING'
            WHEN UPPER(c.concept_name) LIKE '%FAMILY%'
              OR UPPER(c.concept_name) LIKE '%RELATIVE%'        THEN 'FAMILY_HISTORY'
            WHEN UPPER(c.concept_name) LIKE '%ATTEMPT%'         THEN 'ATTEMPT'
            WHEN UPPER(c.concept_name) LIKE '%IDEATION%'
              OR UPPER(c.concept_name) LIKE '%SUICIDAL THOUGHT%' THEN 'IDEATION'
            WHEN UPPER(c.concept_name) LIKE '%RISK%'            THEN 'RISK'
            ELSE 'OTHER' END AS NVARCHAR(30)) AS sr_group
    FROM cdmphi.concept c
    WHERE UPPER(c.concept_name) LIKE '%SUICID%'
       OR UPPER(c.concept_name) LIKE '%C-SSRS%'
);



-- ############################################################################
-- PART 2.  THE COHORT
-- ############################################################################


-- Every MDD diagnosis record inside the study window.
--@block
CREATE TABLE work_schema.rca_mdd_conditions AS (
    SELECT
        co.person_id, co.condition_occurrence_id, co.condition_concept_id,
        co.condition_concept_name,
        COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date) AS condition_date,
        co.condition_start_datetime, co.condition_type_concept_id, co.visit_occurrence_id
    FROM cdmphi.condition_occurrence co
    CROSS JOIN work_schema.rca_params prm
    WHERE EXISTS (SELECT 1 FROM work_schema.rca_mdd_concepts m
                  WHERE m.concept_id = co.condition_concept_id)
      AND COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date)
              BETWEEN prm.window_start AND prm.window_end
);

-- The earliest MDD diagnosis of each person. Ties are broken by record id, so
-- the result is always the same.
--@block
CREATE TABLE work_schema.rca_first_mdd AS (
    SELECT person_id, condition_occurrence_id, condition_concept_id,
           condition_concept_name, condition_date, condition_start_datetime,
           visit_occurrence_id, n_qualifying_records, n_qualifying_days
    FROM (
        SELECT c.*,
               ROW_NUMBER() OVER (PARTITION BY c.person_id
                                  ORDER BY c.condition_date, c.condition_occurrence_id) AS rn,
               COUNT(*) OVER (PARTITION BY c.person_id)                  AS n_qualifying_records,
               COUNT(DISTINCT c.condition_date) OVER (PARTITION BY c.person_id) AS n_qualifying_days
        FROM work_schema.rca_mdd_conditions c
    ) t
    WHERE rn = 1
);

-- The earliest diagnosis must belong to a visit that starts on the same day.
-- If it does not, the person has no index. I do not move on to a later
-- diagnosis.
--@block
CREATE TABLE work_schema.rca_index_visit AS (
    SELECT
        f.person_id,
        f.condition_occurrence_id  AS index_condition_id,
        f.condition_concept_id     AS index_condition_concept_id,
        f.condition_concept_name   AS index_condition_name,
        f.condition_date           AS index_date,
        f.n_qualifying_records, f.n_qualifying_days,
        v.visit_occurrence_id      AS index_visit_id,
        v.visit_concept_id         AS index_visit_concept_id,
        v.visit_concept_name       AS index_visit_name,
        COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date) AS index_visit_start,
        COALESCE(CAST(v.visit_end_datetime   AS DATE), v.visit_end_date)   AS index_visit_end,
        CASE WHEN COALESCE(CAST(v.visit_end_datetime AS DATE), v.visit_end_date) IS NULL THEN NULL
             ELSE DAYS_BETWEEN(COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date),
                               COALESCE(CAST(v.visit_end_datetime   AS DATE), v.visit_end_date))
        END AS index_visit_los_days
    FROM work_schema.rca_first_mdd f
    JOIN cdmphi.visit_occurrence v
      ON v.visit_occurrence_id = f.visit_occurrence_id
     AND v.person_id           = f.person_id
    WHERE f.visit_occurrence_id IS NOT NULL
      AND f.visit_occurrence_id <> 0
      AND COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date) = f.condition_date
);

-- Age at the index date, from the birth date, or from the birth year if the
-- birth date is missing.
--@block
CREATE TABLE work_schema.rca_index_ages AS (
    SELECT c.*, p.gender_concept_id, p.year_of_birth, p.birth_datetime,
           CASE WHEN p.birth_datetime IS NULL THEN 1 ELSE 0 END AS birth_datetime_imputed,
           CASE WHEN p.birth_datetime IS NOT NULL
                     THEN FLOOR(DAYS_BETWEEN(CAST(p.birth_datetime AS DATE), c.index_date) / 365.25)
                WHEN p.year_of_birth IS NOT NULL
                     THEN YEAR(c.index_date) - p.year_of_birth
                ELSE NULL END AS age_at_index
    FROM work_schema.rca_index_visit c
    JOIN cdmphi.person p ON p.person_id = c.person_id
);

-- The index: adults only (18 or older), with a plausible age (at most 120).
--@block
CREATE TABLE work_schema.rca_index AS (
    SELECT a.*
    FROM work_schema.rca_index_ages a
    CROSS JOIN work_schema.rca_params prm
    WHERE a.age_at_index IS NOT NULL
      AND a.age_at_index >= prm.min_age_at_index
      AND a.age_at_index <= 120
);

-- Visits in the 365 days before the index day. The index day itself does not
-- count. A person needs at least one such visit, so I know they were already
-- in care at Mount Sinai.
--@block
CREATE TABLE work_schema.rca_baseline AS (
    SELECT i.person_id, i.index_date,
           COUNT(v.visit_occurrence_id) AS n_baseline_visits,
           COUNT(DISTINCT COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)) AS n_baseline_visit_days,
           MIN(COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)) AS first_baseline_visit,
           MAX(COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)) AS last_baseline_visit
    FROM work_schema.rca_index i
    LEFT JOIN cdmphi.visit_occurrence v
           ON v.person_id = i.person_id
          AND COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)
                BETWEEN ADD_DAYS(i.index_date, -365) AND ADD_DAYS(i.index_date, -1)
    GROUP BY i.person_id, i.index_date
);

-- The first competing psychiatric diagnosis on or before the index, and the
-- first one after it. A code on or before the index excludes the person, at
-- any date, also before the window. A code after the index ends follow-up.
--@block
CREATE TABLE work_schema.rca_psych_history AS (
    SELECT i.person_id,
           MIN(CASE WHEN e.dx_date <= i.index_date THEN e.dx_date END) AS psych_first_pre_date,
           MIN(CASE WHEN e.dx_date >  i.index_date THEN e.dx_date END) AS psych_first_post_date,
           MIN(e.dx_date)                   AS psych_first_any_date,
           COUNT(e.condition_occurrence_id) AS n_psych_records
    FROM work_schema.rca_index i
    LEFT JOIN (
        SELECT co.person_id, co.condition_occurrence_id,
               COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date) AS dx_date
        FROM cdmphi.condition_occurrence co
        WHERE EXISTS (SELECT 1 FROM work_schema.rca_psych_exclusion_concepts p
                      WHERE p.concept_id = co.condition_concept_id)
    ) e ON e.person_id = i.person_id
    GROUP BY i.person_id
);

-- Death date. Persons who died before the index are excluded below.
--@block
CREATE TABLE work_schema.rca_death AS (
    SELECT i.person_id,
           COALESCE(CAST(d.death_datetime AS DATE), d.death_date) AS death_date,
           CASE WHEN COALESCE(CAST(d.death_datetime AS DATE), d.death_date)
                       BETWEEN i.index_date AND prm.window_end THEN 1 ELSE 0 END AS death_in_followup,
           CASE WHEN COALESCE(CAST(d.death_datetime AS DATE), d.death_date) < i.index_date
                THEN 1 ELSE 0 END AS death_before_index
    FROM work_schema.rca_index i
    CROSS JOIN work_schema.rca_params prm
    JOIN cdmphi.death d ON d.person_id = i.person_id
);

-- The cohort. A person is in it if they have an index, at least one baseline
-- visit, no competing diagnosis on or before the index, and did not die
-- before the index.
-- Follow-up ends at the earliest of: the window end, the first competing
-- psychiatric diagnosis after the index, or death.
--@block
CREATE TABLE work_schema.rca_cohort AS (
    SELECT
        i.person_id, i.index_date,
        i.index_condition_id, i.index_condition_concept_id, i.index_condition_name,
        i.index_visit_id, i.index_visit_concept_id, i.index_visit_name,
        i.index_visit_start, i.index_visit_end, i.index_visit_los_days,
        i.age_at_index, i.gender_concept_id,
        i.n_qualifying_records, i.n_qualifying_days,

        b.n_baseline_visits, b.n_baseline_visit_days,
        b.first_baseline_visit, b.last_baseline_visit,

        h.psych_first_post_date,
        d.death_date,
        COALESCE(d.death_in_followup, 0) AS death_in_followup,

        LEAST(prm.window_end,
              COALESCE(h.psych_first_post_date, prm.window_end),
              COALESCE(CASE WHEN d.death_in_followup = 1 THEN d.death_date END,
                       prm.window_end)) AS obs_end_date,

        CASE WHEN d.death_in_followup = 1
                  AND d.death_date <= COALESCE(h.psych_first_post_date, prm.window_end)
                  THEN 'DEATH'
             WHEN h.psych_first_post_date IS NOT NULL
                  AND h.psych_first_post_date < prm.window_end
                  THEN 'PSYCH_DX'
             ELSE 'WINDOW_END' END AS censor_reason,

        YEAR(i.index_date) AS index_year
    FROM work_schema.rca_index i
    CROSS JOIN work_schema.rca_params prm
    JOIN work_schema.rca_baseline b          ON b.person_id  = i.person_id
    JOIN work_schema.rca_psych_history h     ON h.person_id  = i.person_id
    LEFT JOIN work_schema.rca_death d        ON d.person_id  = i.person_id
    WHERE b.n_baseline_visits > 0
      AND h.psych_first_pre_date IS NULL
      AND COALESCE(d.death_before_index, 0) = 0
);



-- ############################################################################
-- PART 3.  ANTIDEPRESSANTS AND ACUTE CARE
-- ############################################################################


-- Drug records of cohort persons between the index and the end of follow-up.
-- I remove racemic ketamine (esketamine stays), and some pharmacy classes that
-- are not antidepressant use (anesthetics, investigational, topical and others).
--@block
CREATE TABLE work_schema.rca_ad_raw AS (
    SELECT
        d.drug_exposure_id, d.person_id, c.index_date, c.obs_end_date,
        d.drug_concept_id, d.drug_concept_name,
        a.category AS drug_category,
        CASE WHEN a.category = 'Augmentation' THEN 'AUG_RX'
             WHEN a.category = 'Others'       THEN 'INTERVENTIONAL_RX'
             ELSE 'AD_RX' END AS event_class,
        d.drug_type_concept_id, dt.concept_name AS drug_type_name,
        COALESCE(CAST(d.drug_exposure_start_datetime AS DATE), d.drug_exposure_start_date) AS start_date,
        COALESCE(CAST(d.drug_exposure_end_datetime   AS DATE), d.drug_exposure_end_date)   AS raw_end_date,
        d.days_supply AS raw_days_supply,
        d.quantity    AS raw_quantity,
        d.visit_occurrence_id
    FROM cdmphi.drug_exposure d
    JOIN work_schema.rca_cohort c ON c.person_id = d.person_id
    JOIN (SELECT DISTINCT descendant_concept_id, category FROM work_schema.rca_ad_concepts) a
      ON a.descendant_concept_id = d.drug_concept_id
    LEFT JOIN cdmphi.concept dt ON dt.concept_id = d.drug_type_concept_id
    CROSS JOIN work_schema.rca_params prm
    WHERE COALESCE(CAST(d.drug_exposure_start_datetime AS DATE), d.drug_exposure_start_date)
              BETWEEN c.index_date AND c.obs_end_date
      AND COALESCE(CAST(d.drug_exposure_start_datetime AS DATE), d.drug_exposure_start_date)
              BETWEEN prm.window_start AND prm.window_end
      AND NOT (
            EXISTS (SELECT 1 FROM cdmphi.concept_ancestor ka
                    WHERE ka.ancestor_concept_id = 785649
                      AND ka.descendant_concept_id = d.drug_concept_id)
            AND NOT EXISTS (SELECT 1 FROM cdmphi.concept_ancestor ea
                    WHERE ea.ancestor_concept_id = 1366610
                      AND ea.descendant_concept_id = d.drug_concept_id))
      AND (d.xtn_pharmaceutical_class_source_concept_name IS NULL
           OR d.xtn_pharmaceutical_class_source_concept_name NOT IN (
                'INVESTIGATIONAL', 'ANTIPRURITICS,TOPICAL',
                'GENERAL ANESTHETICS,INJECTABLE', 'SMOKING DETERRENTS, OTHER',
                'No matching concept', 'ANTIPARKINSONISM DRUGS,OTHER',
                'SEDATIVE-HYPNOTICS,NON-BARBITURATE'))
);

-- The record type of each drug record (order, administration, prescription),
-- and how many days it covers:
--   an administration covers one day, esketamine is a single-day event,
--   otherwise I use days supply (1 to 365), then the end date (1 to 365 days),
--   and if neither is valid, a single day.
-- Coverage never runs past the end of follow-up. Orders are kept here, but
-- they do not enter the event log.
--@block
CREATE TABLE work_schema.rca_ad_coverage AS (
    SELECT
        r.*, rt.record_type,
        CASE WHEN rt.record_type = 'ORDER'             THEN 'ORDER_EXCLUDED'
             WHEN rt.record_type = 'ADMINISTRATION'    THEN 'A_ADMIN_ONE_DAY'
             WHEN r.event_class  = 'INTERVENTIONAL_RX' THEN 'A_POINT_ESKETAMINE'
             WHEN r.raw_days_supply BETWEEN 1 AND 365  THEN 'P1_DAYS_SUPPLY'
             WHEN r.raw_end_date IS NOT NULL
                  AND DAYS_BETWEEN(r.start_date, r.raw_end_date) + 1 BETWEEN 1 AND 365
                                                       THEN 'P2_END_DATE'
             ELSE 'P3_POINT_EVENT_UNKNOWN_DURATION' END AS coverage_tier,

        r.start_date AS coverage_start,

        LEAST(
          CASE WHEN rt.record_type = 'ORDER'             THEN r.start_date
               WHEN rt.record_type = 'ADMINISTRATION'    THEN r.start_date
               WHEN r.event_class  = 'INTERVENTIONAL_RX' THEN r.start_date
               WHEN r.raw_days_supply BETWEEN 1 AND 365
                    THEN ADD_DAYS(r.start_date, CAST(r.raw_days_supply AS INTEGER) - 1)
               WHEN r.raw_end_date IS NOT NULL
                    AND DAYS_BETWEEN(r.start_date, r.raw_end_date) + 1 BETWEEN 1 AND 365
                    THEN r.raw_end_date
               ELSE r.start_date END,
          r.obs_end_date) AS coverage_end,

        CASE WHEN r.raw_end_date IS NULL THEN 0
             WHEN DAYS_BETWEEN(r.start_date, r.raw_end_date) < 0 THEN 1
             WHEN DAYS_BETWEEN(r.start_date, r.raw_end_date) > 365 THEN 1
             ELSE 0 END AS invalid_end_date_flag,

        CASE WHEN r.raw_days_supply BETWEEN 1 AND 365 AND r.raw_quantity > 0
             THEN r.raw_quantity / r.raw_days_supply END AS quantity_per_supply_day
    FROM work_schema.rca_ad_raw r
    JOIN (
        SELECT DISTINCT drug_type_concept_id,
               CASE WHEN UPPER(drug_type_name) LIKE '%ADMINISTRATION%' THEN 'ADMINISTRATION'
                    WHEN UPPER(drug_type_name) LIKE '%ORDER%'          THEN 'ORDER'
                    WHEN UPPER(drug_type_name) LIKE '%PRESCRIPTION%'
                      OR UPPER(drug_type_name) LIKE '%DISPENS%'        THEN 'PRESCRIPTION'
                    ELSE 'UNCLASSIFIED' END AS record_type
        FROM work_schema.rca_ad_raw
    ) rt ON rt.drug_type_concept_id = r.drug_type_concept_id
);

-- Acute psychiatric care: inpatient, emergency, or emergency-to-inpatient
-- visits inside follow-up that carry an MDD diagnosis.
--@block
CREATE TABLE work_schema.rca_acute_visits AS (
    SELECT v.person_id, v.visit_occurrence_id,
           COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date) AS visit_start,
           COALESCE(CAST(v.visit_end_datetime   AS DATE), v.visit_end_date)   AS visit_end,
           v.visit_concept_id, v.visit_concept_name,
           CASE v.visit_concept_id WHEN 9201 THEN 'PSY_IP'
                                   WHEN 9203 THEN 'ED_PSY'
                                   WHEN 262  THEN 'ED_TO_IP'
                                   ELSE 'OTHER_ACUTE' END AS acute_type,
           CASE WHEN COALESCE(CAST(v.visit_end_datetime AS DATE), v.visit_end_date) IS NULL THEN NULL
                ELSE DAYS_BETWEEN(COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date),
                                  COALESCE(CAST(v.visit_end_datetime   AS DATE), v.visit_end_date))
           END AS los_days
    FROM cdmphi.visit_occurrence v
    JOIN work_schema.rca_cohort c
      ON c.person_id = v.person_id
     AND COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)
           BETWEEN c.index_date AND c.obs_end_date
    WHERE v.visit_concept_id IN (9201, 9203, 262)
      AND EXISTS (SELECT 1 FROM cdmphi.condition_occurrence co
                  WHERE co.visit_occurrence_id = v.visit_occurrence_id
                    AND co.person_id = v.person_id
                    AND EXISTS (SELECT 1 FROM work_schema.rca_mdd_concepts m
                                WHERE m.concept_id = co.condition_concept_id))
);



-- ############################################################################
-- PART 4.  STAYS AND OUTCOME
-- ############################################################################


-- One row per hospital stay. A visit that starts inside an earlier visit of
-- the same person is the same stay stored twice, so it is dropped, and the
-- outer stay ends at the latest end of the visits inside it.
-- admission_no counts the person's stays in date order (1 = first).
-- Age comes from the birth date, or from the birth year when it is missing.
--@block
CREATE TABLE work_schema.depression_inpatient_cohort AS (
    WITH cand AS (
        SELECT a.visit_occurrence_id, a.person_id, a.visit_start, a.visit_end,
               a.visit_concept_id, a.acute_type
        FROM work_schema.rca_acute_visits a
        WHERE a.acute_type IN ('PSY_IP', 'ED_TO_IP')
          AND a.visit_end IS NOT NULL
          AND a.visit_end >= a.visit_start
    ),
    outer_stays AS (
        SELECT x.*
        FROM cand x
        WHERE NOT EXISTS (
            SELECT 1 FROM cand y
            WHERE y.person_id = x.person_id
              AND y.visit_occurrence_id <> x.visit_occurrence_id
              AND x.visit_start BETWEEN y.visit_start AND y.visit_end
              AND (   y.visit_start < x.visit_start
                   OR (y.visit_start = x.visit_start
                       AND y.visit_occurrence_id < x.visit_occurrence_id)))
    ),
    stays AS (
        SELECT o.visit_occurrence_id, o.person_id, o.visit_start,
               MAX(n.visit_end) AS stay_end,
               o.visit_concept_id, o.acute_type
        FROM outer_stays o
        JOIN cand n
          ON n.person_id = o.person_id
         AND n.visit_start BETWEEN o.visit_start AND o.visit_end
        GROUP BY o.visit_occurrence_id, o.person_id, o.visit_start,
                 o.visit_concept_id, o.acute_type
    )
    SELECT
        s.visit_occurrence_id                   AS index_visit_occurrence_id,
        s.person_id,
        s.visit_start                           AS admission_date,
        s.stay_end                              AS discharge_date,
        s.visit_concept_id,
        s.acute_type,
        DAYS_BETWEEN(s.visit_start, s.stay_end) AS length_of_stay,
        CASE WHEN p.birth_datetime IS NOT NULL
                  THEN FLOOR(DAYS_BETWEEN(CAST(p.birth_datetime AS DATE), s.visit_start) / 365.25)
             ELSE YEAR(s.visit_start) - p.year_of_birth END AS age_at_admission,
        p.gender_concept_id,
        gc.concept_name                         AS gender,
        c.index_date,
        c.obs_end_date,
        c.death_date,
        ROW_NUMBER() OVER (PARTITION BY s.person_id
                           ORDER BY s.visit_start, s.visit_occurrence_id) AS admission_no
    FROM stays s
    JOIN work_schema.rca_cohort c ON c.person_id = s.person_id
    JOIN cdmphi.person p          ON p.person_id = s.person_id
    LEFT JOIN cdmphi.concept gc   ON gc.concept_id = p.gender_concept_id
);

-- Must return zero rows. Each stay must appear once.
--@block
SELECT index_visit_occurrence_id, COUNT(*) AS n
FROM work_schema.depression_inpatient_cohort
GROUP BY index_visit_occurrence_id
HAVING COUNT(*) > 1;

-- Must return 0. No stay may start inside an earlier stay of the same
-- person.
--@block
SELECT COUNT(*) AS n_nested_admissions
FROM work_schema.depression_inpatient_cohort a
WHERE EXISTS (
    SELECT 1 FROM work_schema.depression_inpatient_cohort b
    WHERE b.person_id = a.person_id
      AND b.index_visit_occurrence_id <> a.index_visit_occurrence_id
      AND a.admission_date BETWEEN b.admission_date AND b.discharge_date
      AND (   b.admission_date < a.admission_date
           OR (b.admission_date = a.admission_date
               AND b.index_visit_occurrence_id < a.index_visit_occurrence_id)));

-- 30-day readmission: any inpatient visit that starts 3 to 30 days after the
-- discharge day.
--@block
CREATE TABLE work_schema.readmission_flag AS (
    SELECT
        c.index_visit_occurrence_id,
        CASE WHEN r.first_readmit_date IS NOT NULL THEN 1 ELSE 0 END AS readmitted,
        DAYS_BETWEEN(c.discharge_date, r.first_readmit_date)         AS days_to_readmission
    FROM work_schema.depression_inpatient_cohort c
    LEFT JOIN (
        SELECT c2.index_visit_occurrence_id,
               MIN(COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)) AS first_readmit_date
        FROM work_schema.depression_inpatient_cohort c2
        JOIN cdmphi.visit_occurrence v
          ON v.person_id = c2.person_id
         AND v.visit_concept_id IN (9201, 262)
         AND v.visit_occurrence_id <> c2.index_visit_occurrence_id
         AND COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)
                        BETWEEN ADD_DAYS(c2.discharge_date, 3) AND ADD_DAYS(c2.discharge_date, 30)
        GROUP BY c2.index_visit_occurrence_id
    ) r ON r.index_visit_occurrence_id = c.index_visit_occurrence_id
);

-- The stays to analyze: the 30 days after discharge lie inside the study
-- window, so the outcome is fully observed.
--@block
CREATE TABLE work_schema.case_sample AS (
    SELECT c.index_visit_occurrence_id AS case_id
    FROM work_schema.depression_inpatient_cohort c
    CROSS JOIN work_schema.rca_params prm
    WHERE ADD_DAYS(c.discharge_date, 30) <= prm.window_end
);



-- ############################################################################
-- PART 5.  THE EVENT LOG
-- ############################################################################


-- All events of each stay:
--   DRUG       antidepressant records (see DEFINITIONS). activity is the
--              ingredient (for example "sertraline"), so all doses and forms
--              of one drug are one treatment.
--   CONDITION  condition records of the stay
--   PROCEDURE  procedure records of the stay
-- A record belongs to the stay when it is linked to the admission visit or
-- dated from admission to discharge.
--@block
CREATE TABLE work_schema.rca_log AS (
    SELECT
        c.person_id,
        c.index_visit_occurrence_id,
        CAST(COALESCE(ing.ingredient, m.drug_concept_name) AS NVARCHAR(255)) AS activity,
        CAST(COALESCE(d.drug_exposure_start_datetime,
                      TO_TIMESTAMP(m.start_date)) AS TIMESTAMP)          AS event_datetime,
        CAST('DRUG' AS NVARCHAR(20))                                     AS event_type,
        CAST(ing.ingredient AS NVARCHAR(100))                            AS ingredient,
        CAST(m.record_type AS NVARCHAR(20))                              AS record_type,
        CAST(m.drug_exposure_id AS BIGINT)                               AS source_id
    FROM work_schema.depression_inpatient_cohort c
    JOIN work_schema.rca_ad_coverage m
      ON m.person_id   = c.person_id
     AND m.event_class = 'AD_RX'
     AND m.record_type <> 'ORDER'
     AND (   m.visit_occurrence_id = c.index_visit_occurrence_id
          OR m.start_date BETWEEN c.admission_date AND c.discharge_date)
    LEFT JOIN cdmphi.drug_exposure d ON d.drug_exposure_id = m.drug_exposure_id
    LEFT JOIN (
        SELECT descendant_concept_id, MIN(ancestor_concept_name) AS ingredient
        FROM work_schema.rca_ad_concepts
        WHERE category NOT IN ('Augmentation', 'Others')
        GROUP BY descendant_concept_id
    ) ing ON ing.descendant_concept_id = m.drug_concept_id

    UNION ALL

    SELECT
        c.person_id,
        c.index_visit_occurrence_id,
        CAST(COALESCE(co.condition_concept_name, 'unknown') AS NVARCHAR(255)),
        CAST(COALESCE(co.condition_start_datetime,
                      TO_TIMESTAMP(co.condition_start_date)) AS TIMESTAMP),
        CAST('CONDITION' AS NVARCHAR(20)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(co.condition_occurrence_id AS BIGINT)
    FROM work_schema.depression_inpatient_cohort c
    JOIN cdmphi.condition_occurrence co
      ON co.person_id = c.person_id
     AND (   co.visit_occurrence_id = c.index_visit_occurrence_id
          OR COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date)
               BETWEEN c.admission_date AND c.discharge_date)

    UNION ALL

    SELECT
        c.person_id,
        c.index_visit_occurrence_id,
        CAST(COALESCE(p.procedure_concept_name, 'unknown') AS NVARCHAR(255)),
        CAST(COALESCE(p.procedure_datetime, TO_TIMESTAMP(p.procedure_date)) AS TIMESTAMP),
        CAST('PROCEDURE' AS NVARCHAR(20)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(20)),
        CAST(p.procedure_occurrence_id AS BIGINT)
    FROM work_schema.depression_inpatient_cohort c
    JOIN cdmphi.procedure_occurrence p
      ON p.person_id = c.person_id
     AND (   p.visit_occurrence_id = c.index_visit_occurrence_id
          OR COALESCE(CAST(p.procedure_datetime AS DATE), p.procedure_date)
               BETWEEN c.admission_date AND c.discharge_date)
);

-- Must return zero rows. Each record may appear once per stay.
--@block
SELECT index_visit_occurrence_id, event_type, source_id, COUNT(*) AS n
FROM work_schema.rca_log
GROUP BY index_visit_occurrence_id, event_type, source_id
HAVING COUNT(*) > 1;



-- ############################################################################
-- PART 6.  PROCESS AND SEVERITY ATTRIBUTES
-- ############################################################################


-- One row per stay and antidepressant (ingredient): the first and last day it
-- was given, counted from the admission day (day 0). A negative day means a
-- record linked to the stay but dated before it, for example in the ED.
-- early_start = 1 when the first record is on day 0 or 1.
--@block
CREATE TABLE work_schema.rca_adm_drug_timing AS (
    SELECT
        t.*,
        CASE WHEN t.first_day <= 1 THEN 1 ELSE 0 END AS early_start
    FROM (
        SELECT
            l.index_visit_occurrence_id,
            l.ingredient,
            MIN(DAYS_BETWEEN(c.admission_date, CAST(l.event_datetime AS DATE))) AS first_day,
            MAX(DAYS_BETWEEN(c.admission_date, CAST(l.event_datetime AS DATE))) AS last_day,
            COUNT(DISTINCT CAST(l.event_datetime AS DATE))                     AS n_days,
            COUNT(*)                                                           AS n_records
        FROM work_schema.rca_log l
        JOIN work_schema.depression_inpatient_cohort c
          ON c.index_visit_occurrence_id = l.index_visit_occurrence_id
        WHERE l.event_type = 'DRUG'
          AND l.ingredient IS NOT NULL
        GROUP BY l.index_visit_occurrence_id, l.ingredient
    ) t
);

-- One row per stay: how many antidepressants, when the first one started,
-- and whether one was stopped and another started later (switch).
--@block
CREATE TABLE work_schema.rca_adm_process AS (
    SELECT
        t.index_visit_occurrence_id,
        COUNT(*)          AS n_ad_ingredients,
        MIN(t.first_day)  AS first_ad_day,
        CASE WHEN MIN(t.first_day) <= 1 THEN 'early' ELSE 'late' END AS ad_timing,
        CASE WHEN MAX(sw.index_visit_occurrence_id) IS NOT NULL
             THEN 1 ELSE 0 END AS ad_switch
    FROM work_schema.rca_adm_drug_timing t
    LEFT JOIN (
        SELECT DISTINCT a.index_visit_occurrence_id
        FROM work_schema.rca_adm_drug_timing a
        JOIN work_schema.rca_adm_drug_timing b
          ON b.index_visit_occurrence_id = a.index_visit_occurrence_id
         AND b.ingredient <> a.ingredient
         AND b.first_day  >  a.last_day
    ) sw ON sw.index_visit_occurrence_id = t.index_visit_occurrence_id
    GROUP BY t.index_visit_occurrence_id
);

-- Suicidal ideation and suicide attempt records of the persons with a stay,
-- from conditions and observations, matched by standard or source concept.
-- The groups come from rca_sr_concept_set (Part 1).
--@block
CREATE TABLE work_schema.rca_adm_sr_dx AS (
    SELECT x.person_id, x.dx_date,
           COALESCE(s1.sr_group, s2.sr_group) AS sr_group
    FROM (
        SELECT co.person_id,
               COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date) AS dx_date,
               co.condition_concept_id        AS cid,
               co.condition_source_concept_id AS scid
        FROM cdmphi.condition_occurrence co
        WHERE co.person_id IN (SELECT person_id FROM work_schema.depression_inpatient_cohort)
          AND (   co.condition_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
               OR co.condition_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set))

        UNION ALL

        SELECT o.person_id,
               COALESCE(CAST(o.observation_datetime AS DATE), o.observation_date),
               o.observation_concept_id,
               o.observation_source_concept_id
        FROM cdmphi.observation o
        WHERE o.person_id IN (SELECT person_id FROM work_schema.depression_inpatient_cohort)
          AND (   o.observation_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
               OR o.observation_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set))
    ) x
    LEFT JOIN work_schema.rca_sr_concept_set s1 ON s1.concept_id = x.cid
    LEFT JOIN work_schema.rca_sr_concept_set s2 ON s2.concept_id = x.scid
    WHERE COALESCE(s1.sr_group, s2.sr_group) IN ('IDEATION', 'ATTEMPT')
);

-- One row per stay with the outcome and all attributes.
--@block
CREATE TABLE work_schema.rca_adm_features AS (
    SELECT
        c.index_visit_occurrence_id,
        c.person_id,
        c.admission_date,
        c.discharge_date,
        c.length_of_stay,
        c.age_at_admission,
        c.gender,
        c.admission_no,
        CASE WHEN c.admission_no = 1 THEN 1 ELSE 0 END AS is_first_admission,
        CASE WHEN EXISTS (SELECT 1 FROM work_schema.case_sample s
                          WHERE s.case_id = c.index_visit_occurrence_id)
             THEN 1 ELSE 0 END AS in_analysis,
        rf.readmitted,
        rf.days_to_readmission,
        CASE WHEN c.death_date BETWEEN c.admission_date AND ADD_DAYS(c.discharge_date, 30)
             THEN 1 ELSE 0 END AS died_by_day30,

        CASE WHEN c.acute_type = 'ED_TO_IP' THEN 1
             WHEN EXISTS (
                  SELECT 1 FROM cdmphi.visit_occurrence v
                  WHERE v.person_id = c.person_id
                    AND v.visit_occurrence_id <> c.index_visit_occurrence_id
                    AND v.visit_concept_id IN (9203, 262)
                    AND COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date)
                          BETWEEN ADD_DAYS(c.admission_date, -1) AND c.admission_date)
             THEN 1 ELSE 0 END AS ed_arrival,
        CASE WHEN EXISTS (
                  SELECT 1 FROM work_schema.rca_adm_sr_dx d
                  WHERE d.person_id = c.person_id
                    AND d.sr_group  = 'IDEATION'
                    AND d.dx_date BETWEEN ADD_DAYS(c.admission_date, -1) AND c.discharge_date)
             THEN 1 ELSE 0 END AS ideation_dx,
        CASE WHEN EXISTS (
                  SELECT 1 FROM work_schema.rca_adm_sr_dx d
                  WHERE d.person_id = c.person_id
                    AND d.sr_group  = 'ATTEMPT'
                    AND d.dx_date BETWEEN ADD_DAYS(c.admission_date, -1) AND c.discharge_date)
             THEN 1 ELSE 0 END AS attempt_dx,

        COALESCE(pr.n_ad_ingredients, 0)  AS n_ad_ingredients,
        pr.first_ad_day,
        COALESCE(pr.ad_timing, 'none')    AS ad_timing,
        COALESCE(pr.ad_switch, 0)         AS ad_switch
    FROM work_schema.depression_inpatient_cohort c
    JOIN work_schema.readmission_flag rf
      ON rf.index_visit_occurrence_id = c.index_visit_occurrence_id
    LEFT JOIN work_schema.rca_adm_process pr
      ON pr.index_visit_occurrence_id = c.index_visit_occurrence_id
);

-- Must return zero rows. Each stay must appear once.
--@block
SELECT index_visit_occurrence_id, COUNT(*) AS n
FROM work_schema.rca_adm_features
GROUP BY index_visit_occurrence_id
HAVING COUNT(*) > 1;



-- ############################################################################
-- PART 7.  SUMMARIES YOU CAN SHARE
-- ############################################################################


-- The cohort in one row, for the stays in the analysis (Table 1 of the paper).
--@block
SELECT
    (SELECT COUNT(*) FROM work_schema.depression_inpatient_cohort)    AS n_admissions_all,
    COUNT(*)                                                       AS n_admissions,
    COUNT(DISTINCT person_id)                                      AS n_patients,
    SUM(readmitted)                                                AS n_readmitted,
    ROUND(100.0 * SUM(readmitted) / COUNT(*), 1)                   AS readmit_pct,
    SUM(is_first_admission)                                        AS n_first_admissions,
    MEDIAN(age_at_admission)                                       AS median_age,
    MEDIAN(length_of_stay)                                         AS median_los,
    ROUND(100.0 * SUM(ed_arrival)  / COUNT(*), 1)                  AS ed_arrival_pct,
    ROUND(100.0 * SUM(ideation_dx) / COUNT(*), 1)                  AS ideation_pct,
    ROUND(100.0 * SUM(attempt_dx)  / COUNT(*), 1)                  AS attempt_pct,
    ROUND(100.0 * SUM(CASE WHEN ad_timing <> 'none' THEN 1 ELSE 0 END) / COUNT(*), 1) AS any_ad_pct,
    ROUND(100.0 * SUM(CASE WHEN ad_timing = 'early' THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN ad_timing <> 'none' THEN 1 ELSE 0 END), 0), 1)       AS early_pct_of_ad,
    ROUND(100.0 * SUM(ad_switch) / COUNT(*), 1)                    AS switch_pct,
    CASE WHEN SUM(died_by_day30) < 11 THEN '<11'
         ELSE TO_NVARCHAR(SUM(died_by_day30)) END                  AS n_died_by_day30
FROM work_schema.rca_adm_features
WHERE in_analysis = 1;

-- 30-day readmission rate by each attribute, for the stays in the analysis.
-- Cells with fewer than 11 stays show as <11.
--@block
SELECT marker, level,
       CASE WHEN COUNT(*) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(*)) END                                     AS n_admissions,
       CASE WHEN COUNT(*) < 11 THEN '<11'
            ELSE TO_NVARCHAR(ROUND(100.0 * SUM(readmitted) / COUNT(*), 1)) END AS readmit_pct
FROM (
    SELECT 'ed_arrival' AS marker, TO_NVARCHAR(ed_arrival) AS level, readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
    UNION ALL
    SELECT 'ideation_dx', TO_NVARCHAR(ideation_dx), readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
    UNION ALL
    SELECT 'attempt_dx', TO_NVARCHAR(attempt_dx), readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
    UNION ALL
    SELECT 'ad_timing', ad_timing, readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
    UNION ALL
    SELECT 'ad_switch', TO_NVARCHAR(ad_switch), readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
    UNION ALL
    SELECT 'is_first_admission', TO_NVARCHAR(is_first_admission), readmitted
    FROM work_schema.rca_adm_features WHERE in_analysis = 1
) t
GROUP BY marker, level
ORDER BY marker, level;

-- The ten most common antidepressants in the analyzed stays, with how often
-- they start early.
--@block
SELECT t.ingredient,
       COUNT(*)                                     AS n_admissions,
       ROUND(100.0 * SUM(t.early_start) / COUNT(*), 1) AS early_pct
FROM work_schema.rca_adm_drug_timing t
JOIN work_schema.case_sample s ON s.case_id = t.index_visit_occurrence_id
GROUP BY t.ingredient
HAVING COUNT(*) >= 11
ORDER BY n_admissions DESC
LIMIT 10;



-- ############################################################################
-- PART 8.  SUICIDE RISK RECORDS IN DETAIL
--
-- Only needed to look at the suicide risk records. The attributes in Part 6 do
-- not use these tables. This part shows that the C-SSRS screening exists only
-- for outpatient visits in this OMOP instance.
-- ############################################################################


-- The persons with at least one stay, with their index date and end of
-- follow-up.
--@block
CREATE TABLE work_schema.rca_sr_cohort AS (
    SELECT c.person_id, c.index_date, c.obs_end_date
    FROM work_schema.rca_cohort c
    WHERE c.person_id IN (SELECT person_id FROM work_schema.depression_inpatient_cohort)
);

-- Every record of these persons whose standard or source concept is in the
-- set, from the four tables, in one shape. Condition and procedure records
-- have no value. Records at any date are kept. days_from_index and
-- in_followup let you pick a time window later.
--@block
CREATE TABLE work_schema.rca_sr_records AS (
    SELECT
        m.person_id,
        CAST('measurement' AS NVARCHAR(30))                                AS source_table,
        CAST(m.measurement_id AS BIGINT)                                   AS record_id,
        m.measurement_concept_id                                           AS concept_id,
        m.measurement_source_concept_id                                    AS source_concept_id,
        CAST(m.measurement_source_value AS NVARCHAR(255))                  AS source_value,
        m.measurement_type_concept_id                                      AS type_concept_id,
        COALESCE(CAST(m.measurement_datetime AS DATE), m.measurement_date) AS record_date,
        COALESCE(m.measurement_datetime, TO_TIMESTAMP(m.measurement_date)) AS record_datetime,
        CAST(m.value_as_number AS DOUBLE)                                  AS value_as_number,
        m.value_as_concept_id,
        CAST(m.value_source_value AS NVARCHAR(255))                        AS value_as_text,
        m.unit_concept_id,
        m.visit_occurrence_id
    FROM cdmphi.measurement m
    JOIN work_schema.rca_sr_cohort k ON k.person_id = m.person_id
    WHERE m.measurement_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
       OR m.measurement_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)

    UNION ALL

    SELECT
        o.person_id,
        CAST('observation' AS NVARCHAR(30)),
        CAST(o.observation_id AS BIGINT),
        o.observation_concept_id,
        o.observation_source_concept_id,
        CAST(o.observation_source_value AS NVARCHAR(255)),
        o.observation_type_concept_id,
        COALESCE(CAST(o.observation_datetime AS DATE), o.observation_date),
        COALESCE(o.observation_datetime, TO_TIMESTAMP(o.observation_date)),
        CAST(o.value_as_number AS DOUBLE),
        o.value_as_concept_id,
        CAST(o.value_as_string AS NVARCHAR(255)),
        o.unit_concept_id,
        o.visit_occurrence_id
    FROM cdmphi.observation o
    JOIN work_schema.rca_sr_cohort k ON k.person_id = o.person_id
    WHERE o.observation_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
       OR o.observation_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)

    UNION ALL

    SELECT
        co.person_id,
        CAST('condition_occurrence' AS NVARCHAR(30)),
        CAST(co.condition_occurrence_id AS BIGINT),
        co.condition_concept_id,
        co.condition_source_concept_id,
        CAST(co.condition_source_value AS NVARCHAR(255)),
        co.condition_type_concept_id,
        COALESCE(CAST(co.condition_start_datetime AS DATE), co.condition_start_date),
        COALESCE(co.condition_start_datetime, TO_TIMESTAMP(co.condition_start_date)),
        CAST(NULL AS DOUBLE),
        CAST(NULL AS INTEGER),
        CAST(NULL AS NVARCHAR(255)),
        CAST(NULL AS INTEGER),
        co.visit_occurrence_id
    FROM cdmphi.condition_occurrence co
    JOIN work_schema.rca_sr_cohort k ON k.person_id = co.person_id
    WHERE co.condition_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
       OR co.condition_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)

    UNION ALL

    SELECT
        p.person_id,
        CAST('procedure_occurrence' AS NVARCHAR(30)),
        CAST(p.procedure_occurrence_id AS BIGINT),
        p.procedure_concept_id,
        p.procedure_source_concept_id,
        CAST(p.procedure_source_value AS NVARCHAR(255)),
        p.procedure_type_concept_id,
        COALESCE(CAST(p.procedure_datetime AS DATE), p.procedure_date),
        COALESCE(p.procedure_datetime, TO_TIMESTAMP(p.procedure_date)),
        CAST(NULL AS DOUBLE),
        CAST(NULL AS INTEGER),
        CAST(NULL AS NVARCHAR(255)),
        CAST(NULL AS INTEGER),
        p.visit_occurrence_id
    FROM cdmphi.procedure_occurrence p
    JOIN work_schema.rca_sr_cohort k ON k.person_id = p.person_id
    WHERE p.procedure_concept_id        IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
       OR p.procedure_source_concept_id IN (SELECT concept_id FROM work_schema.rca_sr_concept_set)
);

-- One row per record, with its group, both concept names, the visit it
-- belongs to, and its timing relative to the index date. The standard
-- concept decides the group. The source concept decides only when the
-- standard concept is not in the set.
--@block
CREATE TABLE work_schema.rca_sr_events AS (
    SELECT
        r.person_id,
        COALESCE(s1.sr_group, s2.sr_group) AS sr_group,
        CASE WHEN s1.concept_id IS NOT NULL AND s2.concept_id IS NOT NULL THEN 'both'
             WHEN s1.concept_id IS NOT NULL THEN 'concept_id'
             ELSE 'source_concept_id' END  AS matched_on,
        r.concept_id,
        sc.concept_name                    AS concept_name,
        sc.vocabulary_id                   AS concept_vocabulary,
        r.source_concept_id,
        ssc.concept_name                   AS source_concept_name,
        ssc.vocabulary_id                  AS source_vocabulary,
        r.source_value,
        r.source_table,
        r.record_id,
        r.record_date,
        r.record_datetime,
        r.value_as_number,
        r.value_as_concept_id,
        vc.concept_name AS value_concept_name,
        r.value_as_text,
        r.unit_concept_id,
        uc.concept_name AS unit_name,
        r.type_concept_id,
        tc.concept_name AS type_name,
        r.visit_occurrence_id,
        v.visit_concept_id,
        vt.concept_name AS visit_type,
        COALESCE(CAST(v.visit_start_datetime AS DATE), v.visit_start_date) AS visit_start,
        COALESCE(CAST(v.visit_end_datetime   AS DATE), v.visit_end_date)   AS visit_end,
        k.index_date,
        k.obs_end_date,
        DAYS_BETWEEN(k.index_date, r.record_date) AS days_from_index,
        CASE WHEN r.record_date BETWEEN k.index_date AND k.obs_end_date
             THEN 1 ELSE 0 END AS in_followup
    FROM work_schema.rca_sr_records r
    JOIN work_schema.rca_sr_cohort k ON k.person_id = r.person_id
    LEFT JOIN work_schema.rca_sr_concept_set s1 ON s1.concept_id = r.concept_id
    LEFT JOIN work_schema.rca_sr_concept_set s2 ON s2.concept_id = r.source_concept_id
    LEFT JOIN cdmphi.concept sc  ON sc.concept_id  = r.concept_id
    LEFT JOIN cdmphi.concept ssc ON ssc.concept_id = r.source_concept_id
    LEFT JOIN cdmphi.concept vc  ON vc.concept_id  = r.value_as_concept_id
    LEFT JOIN cdmphi.concept uc  ON uc.concept_id  = r.unit_concept_id
    LEFT JOIN cdmphi.concept tc  ON tc.concept_id  = r.type_concept_id
    LEFT JOIN cdmphi.visit_occurrence v
           ON v.visit_occurrence_id = r.visit_occurrence_id
          AND v.person_id           = r.person_id
    LEFT JOIN cdmphi.concept vt ON vt.concept_id = v.visit_concept_id
);

-- Must return zero rows. Each record must appear once.
--@block
SELECT source_table, record_id, COUNT(*) AS n
FROM work_schema.rca_sr_events
GROUP BY source_table, record_id
HAVING COUNT(*) > 1;

-- The concept list: records and persons per group and concept pair, the date
-- range, and how many records sit inside follow-up and on a known visit.
-- A concept in the wrong group means the rules in Part 1 need a fix.
--@block
SELECT sr_group, source_table, matched_on,
       concept_id, concept_name, source_concept_id, source_concept_name,
       COUNT(*)                  AS n_records,
       COUNT(DISTINCT person_id) AS n_persons,
       MIN(record_date)          AS first_date,
       MAX(record_date)          AS last_date,
       SUM(in_followup)          AS n_in_followup,
       SUM(CASE WHEN visit_start IS NOT NULL THEN 1 ELSE 0 END) AS n_on_a_visit
FROM work_schema.rca_sr_events
GROUP BY sr_group, source_table, matched_on,
         concept_id, concept_name, source_concept_id, source_concept_name
ORDER BY sr_group, n_records DESC;

-- How the screening answers are stored, per item. Items with fewer than 11
-- persons are left out, so the result can be shared.
--@block
SELECT source_concept_name, concept_name,
       value_as_number, value_concept_name, value_as_text,
       COUNT(*)                  AS n_records,
       COUNT(DISTINCT person_id) AS n_persons
FROM work_schema.rca_sr_events
WHERE sr_group = 'SCREENING'
GROUP BY source_concept_name, concept_name,
         value_as_number, value_concept_name, value_as_text
HAVING COUNT(DISTINCT person_id) >= 11
ORDER BY source_concept_name, n_records DESC;

-- The C-SSRS screener has six yes/no questions. At Mount Sinai they are the
-- flowsheet rows R HH SUICIDE 1 to 5 and R HH SUICIDE A/B YES:
--   Q1  wish to be dead, last month
--   Q2  non-specific active suicidal thoughts, last month
--   Q3  active suicidal ideation with any methods, no plan, no intent
--   Q4  active suicidal ideation with some intent to act, no specific plan
--   Q5  active suicidal ideation with a specific plan and intent
--   Q6  preparatory acts or suicidal behavior, last 3 months
-- Q3 to Q5 are mostly asked only after an earlier yes.
-- One row per C-SSRS answer, with its question number and a clean answer
-- (yes or no). A record counts by its standard concept (the LOINC item) or
-- by its flowsheet row, so another form mapped to the same LOINC items is
-- caught too.
--@block
CREATE TABLE work_schema.rca_sr_cssrs_answers AS (
    SELECT t.*
    FROM (
        SELECT
            e.person_id, e.visit_occurrence_id, e.visit_type,
            e.visit_start, e.visit_end,
            e.record_date, e.record_datetime,
            e.index_date, e.obs_end_date, e.days_from_index, e.in_followup,
            e.source_table, e.record_id,
            CASE
              WHEN e.concept_name = 'Wish to be dead 1 month'
                OR e.source_concept_name = 'R HH SUICIDE 1'       THEN 1
              WHEN e.concept_name = 'Non-specific active suicidal thoughts 1 month'
                OR e.source_concept_name = 'R HH SUICIDE 2'       THEN 2
              WHEN e.concept_name = 'Active suicidal ideation with any methods (not plan) without intent to act 1 month'
                OR e.source_concept_name = 'R HH SUICIDE 3'       THEN 3
              WHEN e.concept_name = 'Active suicidal ideation with some intent to act, without specific plan 1 month'
                OR e.source_concept_name = 'R HH SUICIDE 4'       THEN 4
              WHEN e.concept_name = 'Active suicidal ideation with specific plan and intent 1 month'
                OR e.source_concept_name = 'R HH SUICIDE 5'       THEN 5
              WHEN e.concept_name = 'Preparatory acts or suicidal behavior 3 months'
                OR e.source_concept_name = 'R HH SUICIDE A/B YES' THEN 6
            END AS question_no,
            CASE WHEN LOWER(TRIM(e.value_as_text)) IN ('yes', 'y') THEN 'yes'
                 WHEN LOWER(TRIM(e.value_as_text)) IN ('no', 'n')  THEN 'no'
            END AS answer
        FROM work_schema.rca_sr_events e
        WHERE e.sr_group = 'SCREENING'
    ) t
    WHERE t.question_no IS NOT NULL
);

-- Screening records that are not one of the six questions. A C-SSRS question
-- under another name would show up here.
--@block
SELECT e.concept_name, e.source_concept_name,
       COUNT(*)                    AS n_records,
       COUNT(DISTINCT e.person_id) AS n_persons
FROM work_schema.rca_sr_events e
WHERE e.sr_group = 'SCREENING'
  AND NOT EXISTS (SELECT 1 FROM work_schema.rca_sr_cssrs_answers a
                  WHERE a.source_table = e.source_table
                    AND a.record_id    = e.record_id)
GROUP BY e.concept_name, e.source_concept_name
ORDER BY n_records DESC;

-- One row per screening: all answers of a person on the same visit and day.
-- If a question has both a yes and a no that day, the yes counts.
-- Risk level, by the standard C-SSRS screener rules:
--   high      yes to Q4, Q5 or Q6
--   moderate  yes to Q3
--   low       yes to Q1 or Q2 only
--   none      at least one answer, and all answers are no
--   unknown   no usable answer
-- risk_rank (0 none, 1 low, 2 moderate, 3 high) gives the worst screening of
-- a stay.
--@block
CREATE TABLE work_schema.rca_sr_screenings AS (
    SELECT
        s.*,
        CAST(CASE WHEN s.q4 = 'yes' OR s.q5 = 'yes' OR s.q6 = 'yes' THEN 'high'
                  WHEN s.q3 = 'yes'                                  THEN 'moderate'
                  WHEN s.q1 = 'yes' OR s.q2 = 'yes'                  THEN 'low'
                  WHEN s.n_answered > 0                              THEN 'none'
                  ELSE 'unknown' END AS NVARCHAR(10)) AS risk_level,
        CASE WHEN s.q4 = 'yes' OR s.q5 = 'yes' OR s.q6 = 'yes' THEN 3
             WHEN s.q3 = 'yes'                                  THEN 2
             WHEN s.q1 = 'yes' OR s.q2 = 'yes'                  THEN 1
             WHEN s.n_answered > 0                              THEN 0
             END AS risk_rank
    FROM (
        SELECT
            person_id,
            visit_occurrence_id,
            record_date            AS screening_date,
            MIN(record_datetime)   AS first_answer_ts,
            MIN(visit_type)        AS visit_type,
            MIN(visit_start)       AS visit_start,
            MIN(visit_end)         AS visit_end,
            MIN(index_date)        AS index_date,
            MIN(obs_end_date)      AS obs_end_date,
            MIN(days_from_index)   AS days_from_index,
            MAX(in_followup)       AS in_followup,
            MAX(CASE WHEN question_no = 1 THEN answer END) AS q1,
            MAX(CASE WHEN question_no = 2 THEN answer END) AS q2,
            MAX(CASE WHEN question_no = 3 THEN answer END) AS q3,
            MAX(CASE WHEN question_no = 4 THEN answer END) AS q4,
            MAX(CASE WHEN question_no = 5 THEN answer END) AS q5,
            MAX(CASE WHEN question_no = 6 THEN answer END) AS q6,
            COUNT(DISTINCT CASE WHEN answer IS NOT NULL THEN question_no END) AS n_answered,
            COUNT(*)               AS n_answer_records
        FROM work_schema.rca_sr_cssrs_answers
        GROUP BY person_id, visit_occurrence_id, record_date
    ) s
);

-- One row per person, visit and day with a suicide-related diagnosis or
-- record: has_ideation (suicidal thoughts or ideation) and has_attempt
-- (suicide attempt, also a history of one).
--@block
CREATE TABLE work_schema.rca_sr_dx_flags AS (
    SELECT
        person_id,
        visit_occurrence_id,
        record_date          AS dx_date,
        MIN(visit_type)      AS visit_type,
        MIN(visit_start)     AS visit_start,
        MIN(visit_end)       AS visit_end,
        MIN(index_date)      AS index_date,
        MIN(days_from_index) AS days_from_index,
        MAX(in_followup)     AS in_followup,
        MAX(CASE WHEN sr_group = 'IDEATION' THEN 1 ELSE 0 END) AS has_ideation,
        MAX(CASE WHEN sr_group = 'ATTEMPT'  THEN 1 ELSE 0 END) AS has_attempt,
        COUNT(*)             AS n_records
    FROM work_schema.rca_sr_events
    WHERE sr_group IN ('IDEATION', 'ATTEMPT')
    GROUP BY person_id, visit_occurrence_id, record_date
);

-- Rows and persons per risk level and diagnosis flag. Cells with fewer than
-- 11 persons show as <11.
--@block
SELECT 'screening' AS source, risk_level AS level,
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(*)) END                   AS n_rows,
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(DISTINCT person_id)) END  AS n_persons
FROM work_schema.rca_sr_screenings
GROUP BY risk_level
UNION ALL
SELECT 'diagnosis', 'ideation',
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(*)) END,
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(DISTINCT person_id)) END
FROM work_schema.rca_sr_dx_flags
WHERE has_ideation = 1
UNION ALL
SELECT 'diagnosis', 'attempt',
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(*)) END,
       CASE WHEN COUNT(DISTINCT person_id) < 11 THEN '<11'
            ELSE TO_NVARCHAR(COUNT(DISTINCT person_id)) END
FROM work_schema.rca_sr_dx_flags
WHERE has_attempt = 1;



-- ############################################################################
-- THE EXPORTS
--
-- These files hold patient data. They stay on Mount Sinai systems.
-- Save them in data/real_data/ of the pipeline.
-- ############################################################################


-- The event log of the stays to analyze, in the shape the pipeline reads.
-- gender is the OMOP gender concept (8507 male, 8532 female).
-- Save as event_log_sample.csv.
--@block
SELECT
    e.person_id                                       AS "person_id",
    e.index_visit_occurrence_id                       AS "index_visit_occurrence_id",
    e.activity                                        AS "activity",
    e.event_datetime                                  AS "event_datetime",
    e.event_type                                      AS "event_type",
    YEAR(c.admission_date) - p.year_of_birth          AS "age_at_admission",
    p.gender_concept_id                               AS "gender",
    DAYS_BETWEEN(c.admission_date, c.discharge_date)  AS "length_of_stay",
    COALESCE(rf.readmitted, 0)                        AS "readmitted"
FROM work_schema.rca_log e
JOIN work_schema.depression_inpatient_cohort c
  ON c.index_visit_occurrence_id = e.index_visit_occurrence_id
JOIN cdmphi.person p
  ON p.person_id = e.person_id
LEFT JOIN work_schema.readmission_flag rf
  ON rf.index_visit_occurrence_id = e.index_visit_occurrence_id
WHERE e.index_visit_occurrence_id IN (SELECT case_id FROM work_schema.case_sample)
ORDER BY e.index_visit_occurrence_id, e.event_datetime;

-- One row per stay with all attributes. The pipeline joins it to the event
-- log on index_visit_occurrence_id. Save as rca_adm_features.csv.
--@block
SELECT * FROM work_schema.rca_adm_features
ORDER BY person_id, admission_date;

-- One row per stay and antidepressant with the first and last day.
-- Save as rca_adm_drug_timing.csv.
--@block
SELECT * FROM work_schema.rca_adm_drug_timing
ORDER BY index_visit_occurrence_id, first_day, ingredient;

-- Optional, from Part 8. All suicide risk records.
-- Save as rca_suicide_risk_records.csv.
--@block
SELECT * FROM work_schema.rca_sr_events
ORDER BY person_id, record_datetime, source_table, record_id;

-- Optional, from Part 8. One row per C-SSRS screening with its risk level.
-- Save as rca_cssrs_screenings.csv.
--@block
SELECT * FROM work_schema.rca_sr_screenings
ORDER BY person_id, screening_date, visit_occurrence_id;

-- Optional, from Part 8. One row per day with the ideation and attempt flags.
-- Save as rca_suicide_dx_flags.csv.
--@block
SELECT * FROM work_schema.rca_sr_dx_flags
ORDER BY person_id, dx_date, visit_occurrence_id;



-- ############################################################################
-- CLEAN-UP. Only to run the script again.
--
-- Drops every table this script makes, in reverse order. If you did not run
-- Part 8, skip its six tables at the top.
-- ############################################################################


--@block
DROP TABLE work_schema.rca_sr_dx_flags;
--@block
DROP TABLE work_schema.rca_sr_screenings;
--@block
DROP TABLE work_schema.rca_sr_cssrs_answers;
--@block
DROP TABLE work_schema.rca_sr_events;
--@block
DROP TABLE work_schema.rca_sr_records;
--@block
DROP TABLE work_schema.rca_sr_cohort;
--@block
DROP TABLE work_schema.rca_adm_features;
--@block
DROP TABLE work_schema.rca_adm_sr_dx;
--@block
DROP TABLE work_schema.rca_adm_process;
--@block
DROP TABLE work_schema.rca_adm_drug_timing;
--@block
DROP TABLE work_schema.rca_log;
--@block
DROP TABLE work_schema.case_sample;
--@block
DROP TABLE work_schema.readmission_flag;
--@block
DROP TABLE work_schema.depression_inpatient_cohort;
--@block
DROP TABLE work_schema.rca_acute_visits;
--@block
DROP TABLE work_schema.rca_ad_coverage;
--@block
DROP TABLE work_schema.rca_ad_raw;
--@block
DROP TABLE work_schema.rca_cohort;
--@block
DROP TABLE work_schema.rca_death;
--@block
DROP TABLE work_schema.rca_psych_history;
--@block
DROP TABLE work_schema.rca_baseline;
--@block
DROP TABLE work_schema.rca_index;
--@block
DROP TABLE work_schema.rca_index_ages;
--@block
DROP TABLE work_schema.rca_index_visit;
--@block
DROP TABLE work_schema.rca_first_mdd;
--@block
DROP TABLE work_schema.rca_mdd_conditions;
--@block
DROP TABLE work_schema.rca_sr_concept_set;
--@block
DROP TABLE work_schema.rca_psych_exclusion_concepts;
--@block
DROP TABLE work_schema.rca_psych_exclusion_ancestors;
--@block
DROP TABLE work_schema.rca_mdd_concepts;
--@block
DROP TABLE work_schema.rca_mdd_excluded_concepts;
--@block
DROP TABLE work_schema.rca_mdd_retained_ancestors;
--@block
DROP TABLE work_schema.rca_mdd_exclusion_ancestors;
--@block
DROP TABLE work_schema.rca_mdd_source_concepts;
--@block
DROP TABLE work_schema.rca_mdd_source_ancestors;
--@block
DROP TABLE work_schema.rca_ad_concepts;
--@block
DROP TABLE work_schema.rca_ad_ingredients;
--@block
DROP TABLE work_schema.rca_params;

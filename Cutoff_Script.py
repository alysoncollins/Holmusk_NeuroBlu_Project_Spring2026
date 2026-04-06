#This script contains Master_Cohort() which returns the Cohort for the project using relative cutoff as the standardization
def Master_Cohort():
    return """
-- Identify target drug concept IDs (brand-name based)
WITH DrugsUsed AS (
    SELECT DISTINCT drug_concept_id
    FROM drug_product_lookup
    WHERE brand_name LIKE '%leqembi%'
        OR brand_name LIKE '%kisunla%'
        OR brand_name LIKE '%rexulti%'
        OR brand_name LIKE '%namzaric%'
        OR brand_name LIKE '%aricept%'
        OR brand_name LIKE '%exelon%'
        OR brand_name LIKE '%razadyne%'
        OR brand_name LIKE '%zunveyl%'
        OR brand_name LIKE '%namenda%'
        OR brand_name LIKE '%belsomra%'
        OR brand_name LIKE '%risperdal%'
),

-- First diagnosis date of MCI OR Dementia OR Alzheimer's
CohortDiagnosis AS (
    SELECT
        co.person_id,
        MIN(co.condition_start_date) AS index_date,
        MAX(c.concept_name)          AS diagnosis_type
    FROM condition_occurrence co
    JOIN concept c
        ON co.condition_concept_id = c.concept_id
    WHERE c.concept_name LIKE '%mild cognitive% impairment%'
       OR c.concept_name LIKE '%dementia%'
       OR c.concept_name LIKE '%alzheimer%'
    GROUP BY co.person_id
    HAVING MIN(co.condition_start_date) IS NOT NULL
),

-- One observation period row per patient using the latest end date
ObsPeriod AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM observation_period
    WHERE observation_period_end_date IS NOT NULL
    GROUP BY person_id
),

-- Cohort eligibility: diagnosis + drug exposure + 180d observation + at least one cognitive score
EligibleCohort AS (
    SELECT
        cd.person_id,
        cd.index_date,
        cd.diagnosis_type,
        op.observation_period_end_date
    FROM CohortDiagnosis cd
    JOIN ObsPeriod op
        ON cd.person_id = op.person_id
    WHERE DATEDIFF(op.observation_period_end_date, cd.index_date) >= 180
      AND EXISTS (
          SELECT 1
          FROM drug_exposure de
          JOIN DrugsUsed du ON de.drug_concept_id = du.drug_concept_id
          WHERE de.person_id = cd.person_id
            AND de.drug_exposure_start_date >= cd.index_date
      )
      -- Require at least one valid cognitive score after index date
      AND EXISTS (
          SELECT 1
          FROM measurement m
          JOIN (
              SELECT custom2_str
              FROM measurement_lookup
              WHERE scale IN ('minicog', 'moca', 'mmse')
                AND custom2_str IS NOT NULL
          ) ml ON m.custom2_str = ml.custom2_str
          WHERE m.person_id = cd.person_id
            AND m.value_as_number IS NOT NULL
            AND m.measurement_date >= cd.index_date
      )
),

-- Cutoff parameters per scale
TestCutoffs AS (
    SELECT 'minicog' AS scale, 3.0  AS cutoff, 5.0  AS upper_bound
    UNION ALL SELECT 'mmse',   24.0,            30.0
    UNION ALL SELECT 'moca',   26.0,            30.0
),

-- Standardized cognitive scores for eligible patients only
CognitiveScores AS (
    SELECT
        m.person_id,
        m.measurement_date,
        ml.scale,
        CASE
            WHEN m.value_as_number = tc.cutoff THEN 0
            WHEN m.value_as_number < tc.cutoff THEN -(tc.cutoff - m.value_as_number) / tc.cutoff
            WHEN m.value_as_number > tc.cutoff THEN  (m.value_as_number - tc.cutoff) / (tc.upper_bound - tc.cutoff)
            ELSE NULL
        END AS cutoff_score
    FROM measurement m
    JOIN (
        SELECT custom2_str, scale
        FROM measurement_lookup
        WHERE scale IN ('minicog', 'moca', 'mmse')
          AND custom2_str IS NOT NULL
    ) ml ON m.custom2_str = ml.custom2_str
    JOIN TestCutoffs tc
        ON ml.scale = tc.scale
    JOIN EligibleCohort ec
        ON m.person_id = ec.person_id
    WHERE m.value_as_number IS NOT NULL
        AND m.measurement_date >= ec.index_date
),

-- Average, first, and last cognitive scores computed in a single scan
CogScoreAgg AS (
    SELECT
        person_id,
        AVG(cutoff_score)                                 AS avg_followup_score,
        MIN(CASE WHEN rn_asc  = 1 THEN cutoff_score END) AS first_score,
        MIN(CASE WHEN rn_desc = 1 THEN cutoff_score END) AS last_score
    FROM (
        SELECT
            person_id,
            cutoff_score,
            ROW_NUMBER() OVER (
                PARTITION BY person_id
                ORDER BY measurement_date ASC NULLS LAST
            ) AS rn_asc,
            ROW_NUMBER() OVER (
                PARTITION BY person_id
                ORDER BY measurement_date DESC NULLS LAST
            ) AS rn_desc
        FROM CognitiveScores
    ) ranked
    GROUP BY person_id
),

-- Drug exposure windows scoped to eligible patients only
drug_cohort AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        ec.index_date,
        (DATEDIFF('day',
            de.drug_exposure_start_date,
            COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
        ) + 1) AS cumulative_days_exposed,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(ec.index_date, 30)
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date) >= ec.index_date
            THEN 1 ELSE 0
        END AS exposed_0_30d,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(ec.index_date, 90)
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date) >= DATE_ADD(ec.index_date, 31)
            THEN 1 ELSE 0
        END AS exposed_31_90d,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(ec.index_date, 180)
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date) >= DATE_ADD(ec.index_date, 91)
            THEN 1 ELSE 0
        END AS exposed_91_180d
    FROM drug_exposure de
    INNER JOIN EligibleCohort ec
        ON de.person_id = ec.person_id
    WHERE de.drug_exposure_start_date IS NOT NULL
        AND de.drug_exposure_start_date >= ec.index_date
        AND de.drug_exposure_start_date <= DATE_ADD(ec.index_date, 180)
),

-- Drug ingredient and brand metadata for pivot columns
drug_hierarchy AS (
    SELECT DISTINCT
        dl.drug_concept_id,
        cdim.ingredient_concept_name AS ingredient_level,
        dl.drug_concept_name         AS component_level,
        dpl.brand_name               AS brand_level
    FROM drug_lookup dl
    INNER JOIN clinical_drug_ingredient_mapping cdim
        ON dl.drug_concept_id = cdim.drug_concept_id
    INNER JOIN drug_product_lookup dpl
        ON dl.drug_concept_id = dpl.drug_concept_id
    WHERE cdim.ingredient_concept_name LIKE '%haloperidol%'
        OR cdim.ingredient_concept_name LIKE '%lecanemab%'
        OR cdim.ingredient_concept_name LIKE '%donanemab%'
        OR cdim.ingredient_concept_name LIKE '%brexpiprazole%'
        OR cdim.ingredient_concept_name LIKE '%memantine%'
        OR cdim.ingredient_concept_name LIKE '%donepezil%'
        OR cdim.ingredient_concept_name LIKE '%rivastigmine%'
        OR cdim.ingredient_concept_name LIKE '%galantamine%'
        OR cdim.ingredient_concept_name LIKE '%benzgalantamine%'
        OR cdim.ingredient_concept_name LIKE '%suvorexant%'
        OR cdim.ingredient_concept_name LIKE '%risperidone%'
),

-- Drug exposures collapsed to one row per patient per drug per ingredient
drug_cohort_collapsed AS (
    SELECT
        dc.person_id,
        dc.drug_concept_id,
        dh.ingredient_level,
        dc.index_date,
        SUM(dc.cumulative_days_exposed) AS cumulative_days_exposed,
        MAX(dc.exposed_0_30d)           AS exposed_0_30d,
        MAX(dc.exposed_31_90d)          AS exposed_31_90d,
        MAX(dc.exposed_91_180d)         AS exposed_91_180d
    FROM drug_cohort dc
    LEFT JOIN drug_hierarchy dh
        ON dc.drug_concept_id = dh.drug_concept_id
    GROUP BY
        dc.person_id,
        dc.drug_concept_id,
        dh.ingredient_level,
        dc.index_date
),

-- Patient demographics with unknown concepts labeled rather than excluded
Demographics AS (
    SELECT
        p.person_id,
        CASE
            WHEN p.year_of_birth IS NULL THEN NULL
            ELSE YEAR(cd.index_date) - p.year_of_birth
        END AS age_at_index,
        CASE
            WHEN LOWER(g.concept_name) LIKE '%no matching concept%' OR g.concept_name IS NULL
            THEN 'Unknown' ELSE g.concept_name
        END AS sex,
        CASE
            WHEN LOWER(r.concept_name) LIKE '%no matching concept%' OR r.concept_name IS NULL
            THEN 'Unknown' ELSE r.concept_name
        END AS race,
        CASE
            WHEN LOWER(e.concept_name) LIKE '%no matching concept%' OR e.concept_name IS NULL
            THEN 'Unknown' ELSE e.concept_name
        END AS ethnicity
    FROM person p
    JOIN EligibleCohort cd
        ON p.person_id = cd.person_id
    LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
    LEFT JOIN concept r ON p.race_concept_id = r.concept_id
    LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
)

-- Final output: one row per patient per drug exposure record
SELECT
    ec.person_id,
    csa.first_score,
    csa.last_score,
    (csa.last_score - csa.first_score) AS score_delta,
    csa.avg_followup_score,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity,
    ec.index_date,

    -- Haloperidol
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.cumulative_days_exposed END), 0) AS haloperidol_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_0_30d END), 0)          AS haloperidol_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_31_90d END), 0)         AS haloperidol_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_91_180d END), 0)        AS haloperidol_91_180d,

    -- Lecanemab
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.cumulative_days_exposed END), 0) AS lecanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_0_30d END), 0)           AS lecanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_31_90d END), 0)          AS lecanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_91_180d END), 0)         AS lecanemab_91_180d,

    -- Donanemab
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.cumulative_days_exposed END), 0) AS donanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_0_30d END), 0)           AS donanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_31_90d END), 0)          AS donanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_91_180d END), 0)         AS donanemab_91_180d,

    -- Brexpiprazole
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.cumulative_days_exposed END), 0) AS brexpiprazole_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_0_30d END), 0)           AS brexpiprazole_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_31_90d END), 0)          AS brexpiprazole_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_91_180d END), 0)         AS brexpiprazole_91_180d,

    -- Memantine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.cumulative_days_exposed END), 0) AS memantine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_0_30d END), 0)           AS memantine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_31_90d END), 0)          AS memantine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_91_180d END), 0)         AS memantine_91_180d,

    -- Donepezil
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.cumulative_days_exposed END), 0) AS donepezil_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_0_30d END), 0)           AS donepezil_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_31_90d END), 0)          AS donepezil_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_91_180d END), 0)         AS donepezil_91_180d,

    -- Rivastigmine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.cumulative_days_exposed END), 0) AS rivastigmine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_0_30d END), 0)           AS rivastigmine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_31_90d END), 0)          AS rivastigmine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_91_180d END), 0)         AS rivastigmine_91_180d,

    -- Galantamine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.cumulative_days_exposed END), 0) AS galantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_0_30d END), 0)           AS galantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_31_90d END), 0)          AS galantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_91_180d END), 0)         AS galantamine_91_180d,

    -- Benzgalantamine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.cumulative_days_exposed END), 0) AS benzgalantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_0_30d END), 0)           AS benzgalantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_31_90d END), 0)          AS benzgalantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_91_180d END), 0)         AS benzgalantamine_91_180d,

    -- Suvorexant
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.cumulative_days_exposed END), 0) AS suvorexant_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_0_30d END), 0)           AS suvorexant_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_31_90d END), 0)          AS suvorexant_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_91_180d END), 0)         AS suvorexant_91_180d,

    -- Risperidone
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.cumulative_days_exposed END), 0) AS risperidone_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_0_30d END), 0)           AS risperidone_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_31_90d END), 0)          AS risperidone_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_91_180d END), 0)         AS risperidone_91_180d

FROM EligibleCohort ec
JOIN Demographics d
    ON ec.person_id = d.person_id
JOIN drug_cohort_collapsed dcc
    ON ec.person_id = dcc.person_id
LEFT JOIN drug_hierarchy dh
    ON dcc.drug_concept_id = dh.drug_concept_id
INNER JOIN CogScoreAgg csa
    ON ec.person_id = csa.person_id
GROUP BY
    ec.person_id,
    ec.index_date,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity,
    csa.first_score,
    csa.last_score,
    csa.avg_followup_score
ORDER BY ec.person_id
"""
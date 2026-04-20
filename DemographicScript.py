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
        
     UNION ALL --- USING THE GENERIC NAME OF THE DRUGS
    SELECT DISTINCT drug_concept_id
    FROM drug_lookup
    WHERE drug_concept_name LIKE '%lecanemab%'
    OR drug_concept_name LIKE '%donanemab%'
    OR drug_concept_name LIKE '%brexpiprazole%'
    OR drug_concept_name LIKE '%memantine%'
    OR drug_concept_name LIKE '%donepezil%'
    OR drug_concept_name LIKE '%rivastigmina%'
    OR drug_concept_name LIKE '%galantamine%'
    OR drug_concept_name LIKE '%benzgalantamine%'
    OR drug_concept_name LIKE '%suvorexant%'
    OR drug_concept_name LIKE '%risperidone%'
        
),

-- First diagnosis date of MCI OR Dementia OR Alzheimer's
CohortDiagnosis AS (
    SELECT
        co.person_id,
        MIN(co.condition_start_date) AS index_date,
        MAX(c.icd_name)          AS diagnosis_type
    FROM condition_occurrence co
    JOIN diagnosis_lookup c
        ON co.condition_concept_id = c.icd_concept_id
    WHERE disorder_group = 'dementia'
        OR array_contains(keywords, 'mci')
        OR array_contains(keywords, 'ad')
    GROUP BY co.person_id
    HAVING MIN(co.condition_start_date) IS NOT NULL
),

-- One observation period row per person using the latest end date
ObsPeriod AS (
    SELECT
        person_id,
        MAX(visit_end_datetime) AS observation_period_end_date
    FROM visit_occurrence
    WHERE visit_end_datetime IS NOT NULL
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
    WHERE DATEDIFF('day', cd.index_date, op.observation_period_end_date) >= 180
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

-- Standardized cognitive scores for eligible persons only
CognitiveScores AS (
    SELECT
        m.person_id,
        m.measurement_date,
        ml.scale,
        AVG(
            CASE
                WHEN m.value_as_number = tc.cutoff THEN 0
                WHEN m.value_as_number < tc.cutoff THEN -(tc.cutoff - m.value_as_number) / tc.cutoff
                WHEN m.value_as_number > tc.cutoff THEN  (m.value_as_number - tc.cutoff) / (tc.upper_bound - tc.cutoff)
                ELSE NULL
            END
        ) AS cutoff_score
    FROM measurement m
    JOIN (
        SELECT measurement_concept_id, custom2_str, scale
        FROM measurement_lookup
        WHERE scale IN ('minicog', 'moca', 'mmse')
          AND custom2_str IS NOT NULL
    ) ml ON m.measurement_concept_id = ml.measurement_concept_id
    JOIN TestCutoffs tc
        ON ml.scale = tc.scale
    JOIN EligibleCohort ec
        ON m.person_id = ec.person_id
    WHERE m.value_as_number IS NOT NULL
        AND m.measurement_date >= ec.index_date
        AND m.measurement_date <= ec.index_date + INTERVAL 365 DAY
        AND m.value_as_number <= 30
    GROUP BY
        m.person_id,
        m.measurement_date,
        ml.scale
),

-- rank cognitive scores
CogScoreRanked AS (
    SELECT
        person_id,
        measurement_date,
        scale,
        cutoff_score,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY measurement_date ASC NULLS LAST
        ) AS test_sequence_number,
        LAG(cutoff_score) OVER (
            PARTITION BY person_id
            ORDER BY measurement_date ASC NULLS LAST
        ) AS prev_score,
        LAG(measurement_date) OVER (
            PARTITION BY person_id
            ORDER BY measurement_date ASC NULLS LAST
        ) AS prev_test_date
    FROM CognitiveScores
),

CogScoreWithDelta AS (
    SELECT
        person_id,
        measurement_date,
        scale,
        cutoff_score,
        test_sequence_number,
        prev_score,
        prev_test_date,
        cutoff_score - prev_score AS score_delta_from_last,
        CASE  
            WHEN cutoff_score >= 0 THEN 'IMPROVED'
            ELSE 'WORSE'
        END AS trajectory
    FROM CogScoreRanked
    --WHERE prev_score IS NOT NULL
),

-- Drug exposure windows scoped to eligible persons only
drug_cohort AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        ec.index_date,
        csr.measurement_date AS test_date,
        (DATEDIFF('day',
            de.drug_exposure_start_date,
            COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
        ) + 1) AS cumulative_days_exposed,
        CASE
            WHEN de.drug_exposure_start_date <= csr.measurement_date
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= csr.measurement_date - INTERVAL 30 DAY
            THEN 1 ELSE 0
        END AS exposed_0_30d,
        CASE
            WHEN de.drug_exposure_start_date <= csr.measurement_date - INTERVAL 31 DAY
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= csr.measurement_date - INTERVAL 90 DAY
            THEN 1 ELSE 0
        END AS exposed_31_90d,
        CASE
            WHEN de.drug_exposure_start_date <= csr.measurement_date - INTERVAL 91 DAY
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= csr.measurement_date - INTERVAL 180 DAY
            THEN 1 ELSE 0
        END AS exposed_91_180d
    FROM drug_exposure de
    JOIN CogScoreWithDelta csr
        ON de.person_id = csr.person_id
    JOIN EligibleCohort ec
        ON de.person_id = ec.person_id
    WHERE de.drug_exposure_start_date <= csr.measurement_date
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

-- Drug exposures collapsed to one row per person per drug per ingredient
drug_cohort_collapsed AS (
    SELECT
        dc.person_id,
        dc.test_date,
        dc.drug_concept_id,
        dh.ingredient_level,
        SUM(dc.cumulative_days_exposed) AS cumulative_days_exposed,
        MAX(dc.exposed_0_30d)           AS exposed_0_30d,
        MAX(dc.exposed_31_90d)          AS exposed_31_90d,
        MAX(dc.exposed_91_180d)         AS exposed_91_180d
    FROM drug_cohort dc
    LEFT JOIN drug_hierarchy dh
        ON dc.drug_concept_id = dh.drug_concept_id
    GROUP BY
        dc.person_id,
        dc.test_date,
        dc.drug_concept_id,
        dh.ingredient_level
),

-- person demographics with unknown concepts labeled rather than excluded
Demographics AS (
    SELECT
        p.person_id,
        CASE
            WHEN p.year_of_birth IS NULL THEN NULL
            ELSE YEAR(cd.index_date) - p.year_of_birth
        END AS age_at_index,

        -- Sex
        g.concept_name as 'sex',

        -- Race
        r.concept_name as 'race',

        -- Ethnicity
        e.concept_name as 'ethnicity'

    FROM person p
    JOIN EligibleCohort cd
        ON p.person_id = cd.person_id
    LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
    LEFT JOIN concept r ON p.race_concept_id = r.concept_id
    LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
)

-- Final output: one row per person per drug exposure record
SELECT
    ec.person_id,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity

    
FROM CogScoreWithDelta csr
LEFT JOIN EligibleCohort ec 
    on csr.person_id = ec.person_id
JOIN Demographics d
    ON ec.person_id = d.person_id
GROUP BY
    ec.person_id,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity
    
ORDER BY ec.person_id
"""
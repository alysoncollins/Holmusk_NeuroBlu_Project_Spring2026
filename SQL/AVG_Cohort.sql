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
    WHERE CAST(CAST(op.observation_period_end_date AS DATE) 
           - CAST(cd.index_date AS DATE) AS INT) >= 180
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
                WHEN COALESCE(m.value_as_number, 0) = tc.cutoff THEN 0
                WHEN COALESCE(m.value_as_number, 0) < tc.cutoff THEN -(tc.cutoff - COALESCE(m.value_as_number, 0)) / tc.cutoff
                WHEN COALESCE(m.value_as_number, 0) > tc.cutoff THEN  (COALESCE(m.value_as_number, 0) - tc.cutoff) / (tc.upper_bound - tc.cutoff)
                ELSE NULL
            END
        ) AS cutoff_score
    FROM measurement m
    JOIN (
        SELECT measurement_concept_id, custom2_str, scale, scale_item
        FROM measurement_lookup
        WHERE scale IN ('minicog', 'moca', 'mmse')
          AND custom2_str IS NOT NULL
    ) ml ON m.measurement_concept_id = ml.measurement_concept_id
    JOIN TestCutoffs tc
        ON ml.scale = tc.scale
    JOIN EligibleCohort ec
        ON m.person_id = ec.person_id
    WHERE
        -- Keep rows where value is not null OR where it's a total score row (scale_item = 0)
        (m.value_as_number IS NOT NULL OR ml.scale_item = 0)
        AND m.measurement_date >= ec.index_date
        AND m.measurement_date <= ec.index_date + INTERVAL 365 DAY
        AND COALESCE(m.value_as_number, 0) <= 30
    GROUP BY
        m.person_id,
        m.measurement_date,
        ml.scale
),

-- Average standardized scores across scales on the same day
CogScoresAveragedByDay AS (
    SELECT
        person_id,
        measurement_date,
        AVG(cutoff_score) AS cutoff_score
    FROM CognitiveScores
    GROUP BY
        person_id,
        measurement_date
),

-- Rank cognitive scores
CogScoreRanked AS (
    SELECT
        person_id,
        measurement_date,
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
    FROM CogScoresAveragedByDay
),

CogScoreWithDelta AS (
    SELECT
        person_id,
        measurement_date,
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
),

-- Drug exposure windows scoped to eligible persons only
drug_cohort AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        ec.index_date,
        csr.measurement_date AS test_date,
        (CAST(CAST(COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date) AS DATE)
     - CAST(de.drug_exposure_start_date AS DATE) AS INT) + 1) AS cumulative_days_exposed,
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

DrugExposureWide AS (
    SELECT
        dcc.person_id,
        dcc.test_date,
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
    FROM drug_cohort_collapsed dcc
    LEFT JOIN drug_hierarchy dh
        ON dcc.drug_concept_id = dh.drug_concept_id
    GROUP BY dcc.person_id, dcc.test_date
),

-- person demographics with unknown concepts labeled rather than excluded
Demographics AS (
    SELECT DISTINCT
        p.person_id,
        CASE
            WHEN p.year_of_birth IS NULL THEN NULL
            ELSE YEAR(cd.index_date) - p.year_of_birth
        END AS age_at_index,

        -- Sex
        CASE WHEN LOWER(g.concept_name) = 'male'                                     THEN 1 ELSE 0 END AS sex_male,
        CASE WHEN LOWER(g.concept_name) = 'female'                                   THEN 1 ELSE 0 END AS sex_female,
        CASE WHEN LOWER(g.concept_name) = 'no matching concept' OR g.concept_name IS NULL THEN 1 ELSE 0 END AS sex_unknown,

        -- Race
        CASE WHEN LOWER(r.concept_name) = 'white'                                    THEN 1 ELSE 0 END AS race_white,
        CASE WHEN LOWER(r.concept_name) = 'black or african american'                THEN 1 ELSE 0 END AS race_black_or_african_american,
        CASE WHEN LOWER(r.concept_name) = 'asian'                                    THEN 1 ELSE 0 END AS race_asian,
        CASE WHEN LOWER(r.concept_name) = 'american indian or alaska native'         THEN 1 ELSE 0 END AS race_american_indian_or_alaska_native,
        CASE WHEN LOWER(r.concept_name) = 'native hawaiian or other pacific islander' THEN 1 ELSE 0 END AS race_native_hawaiian_or_other_pacific_islander,
        CASE WHEN LOWER(r.concept_name) = 'other race'                               THEN 1 ELSE 0 END AS race_other,
        CASE WHEN LOWER(r.concept_name) = 'no matching concept' OR r.concept_name IS NULL THEN 1 ELSE 0 END AS race_unknown,

        -- Ethnicity
        CASE WHEN LOWER(e.concept_name) = 'not hispanic or latino'                   THEN 1 ELSE 0 END AS ethnicity_not_hispanic_or_latino,
        CASE WHEN LOWER(e.concept_name) = 'hispanic or latino'                       THEN 1 ELSE 0 END AS ethnicity_hispanic_or_latino,
        CASE WHEN LOWER(e.concept_name) = 'no matching concept' OR e.concept_name IS NULL THEN 1 ELSE 0 END AS ethnicity_unknown

    FROM person p
    JOIN EligibleCohort cd
        ON p.person_id = cd.person_id
    LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
    LEFT JOIN concept r ON p.race_concept_id = r.concept_id
    LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
),

-- Raw lab measurements for the target concept IDs, eligible persons only
LabsCohort AS (
    SELECT
        m.person_id,
        m.measurement_id,
        m.measurement_concept_id,
        m.measurement_datetime,
        m.value_as_number,
        ec.index_date
    FROM measurement m
    INNER JOIN EligibleCohort ec
        ON m.person_id = ec.person_id
    WHERE m.measurement_concept_id IN (
        3003722, 3050174, 3043102, 42868556, 1469579,
        1092155, 1259491, 3011498, 3029139, 3042151,
        1761505, 1617650, 1616613, 3042810, 42868555, 1617024
    )
      --AND m.value_as_number IS NOT NULL
),

-- Row-number + lag to identify most-recent value and its predecessor
LabsRanked AS (
    SELECT
        person_id,
        measurement_id,
        measurement_concept_id,
        measurement_datetime,
        value_as_number,
        ROW_NUMBER() OVER (
            PARTITION BY person_id, measurement_concept_id
            ORDER BY measurement_datetime DESC, measurement_id DESC
        ) AS rn,
        LAG(value_as_number) OVER (
            PARTITION BY person_id, measurement_concept_id
            ORDER BY measurement_datetime ASC, measurement_id ASC
        ) AS previous_score,
        LAG(measurement_datetime) OVER (
            PARTITION BY person_id, measurement_concept_id
            ORDER BY measurement_datetime ASC, measurement_id ASC
        ) AS previous_score_datetime
    FROM LabsCohort
),

LabsMostRecent AS (
    SELECT
        csr.person_id,
        measurement_id,
        csr.measurement_date AS test_date,
        lr.measurement_concept_id,
        lr.value_as_number AS most_recent_score,
        lr.measurement_datetime,
        lr.previous_score AS previous_value
    FROM CogScoreWithDelta csr
    JOIN LabsRanked lr
        ON lr.person_id = csr.person_id
       AND lr.measurement_datetime <= csr.measurement_date
       AND lr.rn = 1 
),

-- Rolling 90-day mean/median anchored to each person's most-recent measurement
LabsRollingStats AS (
    SELECT
        csr.person_id,
        csr.measurement_date AS test_date,
        lc.measurement_concept_id,

        AVG(lc.value_as_number) AS rolling_mean_90d,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.value_as_number) AS rolling_median_90d,
        COUNT(*) AS n_labs_90d

    FROM CogScoreWithDelta csr
    JOIN LabsCohort lc
        ON lc.person_id = csr.person_id
       AND lc.measurement_datetime BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
    GROUP BY csr.person_id, csr.measurement_date, lc.measurement_concept_id
),

-- Abnormal flag for the most-recent measurement against reference range
LabsFlag AS (
    SELECT
        lp.person_id,
        lp.test_date,
        lp.measurement_concept_id,
        CASE
            WHEN lp.most_recent_score < m.range_low THEN 1
            WHEN lp.most_recent_score > m.range_high THEN 1
            ELSE 0
        END AS abnormal_flag
    FROM LabsMostRecent lp
    LEFT JOIN measurement m
        ON lp.person_id = m.person_id
       AND lp.measurement_concept_id = m.measurement_concept_id
       AND lp.measurement_datetime = m.measurement_datetime
       AND m.measurement_id = lp.measurement_id
),

-- Collapse all lab metrics to one wide row per person via conditional aggregation
-- Each concept_id becomes a column group: most_recent, previous, mean_90d, median_90d, abnormal_flag
-- Rename column aliases below if friendlier concept names are preferred over concept IDs
LabsAggPerTest AS (
    SELECT
        mr.person_id,
        mr.test_date,

        -- Concept 3003722
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN mr.most_recent_score   END) AS lab_3003722_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN rs.rolling_mean_90d     END) AS lab_3003722_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN rs.rolling_median_90d   END) AS lab_3003722_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN lf.abnormal_flag        END) AS lab_3003722_abnormal_flag,

        -- Concept 3050174
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN mr.most_recent_score   END) AS lab_3050174_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN rs.rolling_mean_90d     END) AS lab_3050174_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN rs.rolling_median_90d   END) AS lab_3050174_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN lf.abnormal_flag        END) AS lab_3050174_abnormal_flag,

        -- Concept 3043102
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN mr.most_recent_score   END) AS lab_3043102_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN rs.rolling_mean_90d     END) AS lab_3043102_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN rs.rolling_median_90d   END) AS lab_3043102_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN lf.abnormal_flag        END) AS lab_3043102_abnormal_flag,

        -- Concept 42868556
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN mr.most_recent_score   END) AS lab_42868556_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN rs.rolling_mean_90d     END) AS lab_42868556_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN rs.rolling_median_90d   END) AS lab_42868556_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN lf.abnormal_flag        END) AS lab_42868556_abnormal_flag,

        -- Concept 1469579
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN mr.most_recent_score   END) AS lab_1469579_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN rs.rolling_mean_90d     END) AS lab_1469579_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN rs.rolling_median_90d   END) AS lab_1469579_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN lf.abnormal_flag        END) AS lab_1469579_abnormal_flag,

        -- Concept 1092155
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN mr.most_recent_score   END) AS lab_1092155_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN rs.rolling_mean_90d     END) AS lab_1092155_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN rs.rolling_median_90d   END) AS lab_1092155_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN lf.abnormal_flag        END) AS lab_1092155_abnormal_flag,

        -- Concept 1259491
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN mr.most_recent_score   END) AS lab_1259491_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN rs.rolling_mean_90d     END) AS lab_1259491_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN rs.rolling_median_90d   END) AS lab_1259491_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN lf.abnormal_flag        END) AS lab_1259491_abnormal_flag,

        -- Concept 3011498
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN mr.most_recent_score   END) AS lab_3011498_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN rs.rolling_mean_90d     END) AS lab_3011498_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN rs.rolling_median_90d   END) AS lab_3011498_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN lf.abnormal_flag        END) AS lab_3011498_abnormal_flag,

        -- Concept 3029139
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN mr.most_recent_score   END) AS lab_3029139_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN rs.rolling_mean_90d     END) AS lab_3029139_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN rs.rolling_median_90d   END) AS lab_3029139_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN lf.abnormal_flag        END) AS lab_3029139_abnormal_flag,

        -- Concept 3042151
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN mr.most_recent_score   END) AS lab_3042151_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN rs.rolling_mean_90d     END) AS lab_3042151_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN rs.rolling_median_90d   END) AS lab_3042151_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN lf.abnormal_flag        END) AS lab_3042151_abnormal_flag,

        -- Concept 1761505
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN mr.most_recent_score   END) AS lab_1761505_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN rs.rolling_mean_90d     END) AS lab_1761505_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN rs.rolling_median_90d   END) AS lab_1761505_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN lf.abnormal_flag        END) AS lab_1761505_abnormal_flag,

        -- Concept 1617650
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN mr.most_recent_score   END) AS lab_1617650_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN rs.rolling_mean_90d     END) AS lab_1617650_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN rs.rolling_median_90d   END) AS lab_1617650_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN lf.abnormal_flag        END) AS lab_1617650_abnormal_flag,

        -- Concept 1616613
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN mr.most_recent_score   END) AS lab_1616613_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN rs.rolling_mean_90d     END) AS lab_1616613_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN rs.rolling_median_90d   END) AS lab_1616613_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN lf.abnormal_flag        END) AS lab_1616613_abnormal_flag,

        -- Concept 3042810
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN mr.most_recent_score   END) AS lab_3042810_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN rs.rolling_mean_90d     END) AS lab_3042810_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN rs.rolling_median_90d   END) AS lab_3042810_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN lf.abnormal_flag        END) AS lab_3042810_abnormal_flag,

        -- Concept 42868555
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN mr.most_recent_score   END) AS lab_42868555_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN rs.rolling_mean_90d     END) AS lab_42868555_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN rs.rolling_median_90d   END) AS lab_42868555_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN lf.abnormal_flag        END) AS lab_42868555_abnormal_flag,

        -- Concept 1617024
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN mr.most_recent_score   END) AS lab_1617024_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN rs.rolling_mean_90d     END) AS lab_1617024_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN rs.rolling_median_90d   END) AS lab_1617024_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN lf.abnormal_flag        END) AS lab_1617024_abnormal_flag

    FROM LabsMostRecent mr
    LEFT JOIN LabsRollingStats rs
        ON  mr.person_id              = rs.person_id
        AND mr.measurement_concept_id = rs.measurement_concept_id
        AND mr.test_date = rs.test_date
    LEFT JOIN LabsFlag lf
        ON  mr.person_id              = lf.person_id
        AND mr.measurement_concept_id = lf.measurement_concept_id
        AND mr.test_date = lf.test_date
    GROUP BY mr.person_id, mr.test_date
),
procedures AS (
    SELECT person_id, procedure_concept_id, procedure_date
    FROM procedure_occurrence
    WHERE procedure_concept_id IN (
        '2211329', '2211328', '2211327', '2211332', '2211330',
        '2211353','2211351','2211719','2212018','2212056','2212053'
    )
),

labs AS (
    SELECT
        person_id,
        MAX(measurement_date) AS most_recent_measurement
    FROM measurement
    WHERE measurement_concept_id IN (
        '3003722','3050174','3043102','42868556','1469579',
        '1092155','1259491','3011498','3029139','3042151',
        '1761505','1617650','1616613','3042810','42868555','1617024'
    )
    GROUP BY person_id
),

ProceduresPerTest AS (
    SELECT
        csr.person_id,
        csr.measurement_date AS test_date,

        -- CONCEPT: 2211329 computed tomography, head or brain; without contrast material, followed by contrast material(s) and further sections
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211329,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211329,

        -- CONCEPT: 2211328 computed tomography, head or brain; with contrast material(s)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211328,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211328,

        -- CONCEPT: 2211327 computed tomography, head or brain; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211327,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211327,

        -- CONCEPT: 2211332 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material, followed by contrast material(s) and further sections  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211332,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211332,

        -- CONCEPT: 2211330 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211330,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211330,

        -- CONCEPT: 2211353 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material, followed by contrast material(s) and further sequences 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211353,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211353,

        -- CONCEPT: 2211351 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211351,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211351,

        -- CONCEPT: 2211719 magnetic resonance spectroscopy 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211719,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211719,

        -- CONCEPT: 2212018 brain imaging, positron emission tomography (pet); metabolic evaluation   
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212018,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212018,

        -- CONCEPT: 2212056 positron emission tomography (pet) with concurrently acquired computed tomography (ct) for attenuation correction and anatomical localization imaging; limited area (eg, chest, head/neck)    
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212056,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212056,

        -- CONCEPT: 2212053 positron emission tomography (pet) imaging; limited area (eg, chest, head/neck)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 180 DAY
                                      AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212053,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date BETWEEN csr.measurement_date - INTERVAL 90 DAY
                                      AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212053

    FROM CogScoreWithDelta csr
    LEFT JOIN (
        -- pre-filter to only your target concept IDs before joining
        SELECT person_id, procedure_concept_id, procedure_date
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (
            '2211329','2211328','2211327','2211332','2211330',
            '2211353','2211351','2211719','2212018','2212056','2212053'
        )
    ) p ON p.person_id = csr.person_id
    GROUP BY csr.person_id, csr.measurement_date
)

-- Final output: one row per person per drug exposure record
SELECT
    ec.person_id,
    ec.index_date,
    csr.cutoff_score,
    csr.measurement_date AS test_date,
    csr.prev_test_date,
    csr.prev_score,
    csr.score_delta_from_last,
    csr.trajectory,
    d.age_at_index,
    d.sex_male,
    d.sex_female,
    d.sex_unknown,
    d.race_white,
    d.race_black_or_african_american,
    d.race_asian,
    d.race_american_indian_or_alaska_native,
    d.race_native_hawaiian_or_other_pacific_islander,
    d.race_other,
    d.race_unknown,
    d.ethnicity_not_hispanic_or_latino,
    d.ethnicity_hispanic_or_latino,
    d.ethnicity_unknown,

    dew.haloperidol_days,
    dew.haloperidol_0_30d,
    dew.haloperidol_31_90d,
    dew.haloperidol_91_180d,

    dew.lecanemab_days,
    dew.lecanemab_0_30d,
    dew.lecanemab_31_90d,
    dew.lecanemab_91_180d,

    dew.donanemab_days,
    dew.donanemab_0_30d,
    dew.donanemab_31_90d,
    dew.donanemab_91_180d,

    dew.brexpiprazole_days,
    dew.brexpiprazole_0_30d,
    dew.brexpiprazole_31_90d,
    dew.brexpiprazole_91_180d,

    dew.memantine_days,
    dew.memantine_0_30d,
    dew.memantine_31_90d,
    dew.memantine_91_180d,

    dew.donepezil_days,
    dew.donepezil_0_30d,
    dew.donepezil_31_90d,
    dew.donepezil_91_180d,

    dew.rivastigmine_days,
    dew.rivastigmine_0_30d,
    dew.rivastigmine_31_90d,
    dew.rivastigmine_91_180d,

    dew.galantamine_days,
    dew.galantamine_0_30d,
    dew.galantamine_31_90d,
    dew.galantamine_91_180d,

    dew.benzgalantamine_days,
    dew.benzgalantamine_0_30d,
    dew.benzgalantamine_31_90d,
    dew.benzgalantamine_91_180d,

    dew.suvorexant_days,
    dew.suvorexant_0_30d,
    dew.suvorexant_31_90d,
    dew.suvorexant_91_180d,

    dew.risperidone_days,
    dew.risperidone_0_30d,
    dew.risperidone_31_90d,
    dew.risperidone_91_180d,

    -- ==========================================================
    -- 3. LAB METRICS (Most Recent, Mean 90d, Median 90d, Flag)
    -- ==========================================================
    -- IDs: 3003722, 3050174, 3043102, 42868556, 1469579
    COALESCE(la.lab_3003722_most_recent, 0) AS amyloid_associated_protein_in_serum_recent, COALESCE(la.lab_3003722_mean_90d, 0) AS amyloid_associated_protein_in_serum_mean_90d, COALESCE(la.lab_3003722_median_90d, 0) AS amyloid_associated_protein_in_serum_median_90d, COALESCE(la.lab_3003722_abnormal_flag, 0) AS amyloid_associated_protein_in_serum_abn, --amyloid_associated_protein_in_serum
    COALESCE(la.lab_3050174_most_recent, 0) AS ykl_40_in_serum_recent, COALESCE(la.lab_3050174_mean_90d, 0) AS ykl_40_in_serum_mean_90d, COALESCE(la.lab_3050174_median_90d, 0) AS ykl_40_in_serum_median_90d, COALESCE(la.lab_3050174_abnormal_flag, 0) AS ykl_40_in_serum_abn, --ykl_40_in_serum
    COALESCE(la.lab_3043102_most_recent, 0) AS amyloid_beta_42_peptide_in_plasma_recent, COALESCE(la.lab_3043102_mean_90d, 0) AS amyloid_beta_42_peptide_in_plasma_mean_90d, COALESCE(la.lab_3043102_median_90d, 0) AS amyloid_beta_42_peptide_in_plasma_median_90d, COALESCE(la.lab_3043102_abnormal_flag, 0) AS amyloid_beta_42_peptide_in_plasma_abn, --amyloid_beta_42_peptide_in_plasma
    COALESCE(la.lab_42868556_most_recent, 0) AS amyloid_beta_40_peptide_in_plasma_recent, COALESCE(la.lab_42868556_mean_90d, 0) AS amyloid_beta_40_peptide_in_plasma_mean_90d, COALESCE(la.lab_42868556_median_90d, 0) AS amyloid_beta_40_peptide_in_plasma_median_90d, COALESCE(la.lab_42868556_abnormal_flag, 0) AS amyloid_beta_40_peptide_in_plasma_abn, --amyloid_beta_40_peptide_in_plasma
    COALESCE(la.lab_1469579_most_recent, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_plasma_recent, COALESCE(la.lab_1469579_mean_90d, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_plasma_mean_90d, COALESCE(la.lab_1469579_median_90d, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_plasma_median_90d, COALESCE(la.lab_1469579_abnormal_flag, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_plasma_abn, --amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_plasma

    -- IDs: 1092155, 1259491, 3011498, 3029139, 3042151
    COALESCE(la.lab_1092155_most_recent, 0) AS tau_protein_phosphorylated_217_in_serum_or_plasma_by_immunoassay_recent, COALESCE(la.lab_1092155_mean_90d, 0) AS tau_protein_phosphorylated_217_in_serum_or_plasma_by_immunoassay_mean_90d, COALESCE(la.lab_1092155_median_90d, 0) AS tau_protein_phosphorylated_217_in_serum_or_plasma_by_immunoassay_median_90d, COALESCE(la.lab_1092155_abnormal_flag, 0) AS tau_protein_phosphorylated_217_in_serum_or_plasma_by_immunoassay_abn, --tau_protein_phosphorylated_217_in_serum_or_plasma_by_immunoassay
    COALESCE(la.lab_1259491_most_recent, 0) AS phosphorylated_tau_181_in_plasma_by_immunoassay_recent, COALESCE(la.lab_1259491_mean_90d, 0) AS phosphorylated_tau_181_in_plasma_by_immunoassay_mean_90d, COALESCE(la.lab_1259491_median_90d, 0) AS phosphorylated_tau_181_in_plasma_by_immunoassay_median_90d, COALESCE(la.lab_1259491_abnormal_flag, 0) AS phosphorylated_tau_181_in_plasma_by_immunoassay_abn, --phosphorylated_tau_181_in_plasma_by_immunoassay
    COALESCE(la.lab_3011498_most_recent, 0) AS apoe_gene_mutations_found_in_blood_or_tissue_by_molecular_genetics_method_nominal_recent, COALESCE(la.lab_3011498_mean_90d, 0) AS apoe_gene_mutations_found_in_blood_or_tissue_by_molecular_genetics_method_nominal_mean_90d, COALESCE(la.lab_3011498_median_90d, 0) AS apoe_gene_mutations_found_in_blood_or_tissue_by_molecular_genetics_method_nominal_median_90d, COALESCE(la.lab_3011498_abnormal_flag, 0) AS apoe_gene_mutations_found_in_blood_or_tissue_by_molecular_genetics_method_nominal_abn, --apoe_gene_mutations_found_in_blood_or_tissue_by_molecular_genetics_method_nominal
    COALESCE(la.lab_3029139_most_recent, 0) AS apoe_gene_alleles_e2_and_e3_and_e4_in_blood_or_tissue_by_molecular_genetics_method_nominal_recent, COALESCE(la.lab_3029139_mean_90d, 0) AS apoe_gene_alleles_e2_and_e3_and_e4_in_blood_or_tissue_by_molecular_genetics_method_nominal_mean_90d, COALESCE(la.lab_3029139_median_90d, 0) AS apoe_gene_alleles_e2_and_e3_and_e4_in_blood_or_tissue_by_molecular_genetics_method_nominal_median_90d, COALESCE(la.lab_3029139_abnormal_flag, 0) AS apoe_gene_alleles_e2_and_e3_and_e4_in_blood_or_tissue_by_molecular_genetics_method_nominal_abn, --apoe_gene_alleles_e2_and_e3_and_e4_in_blood_or_tissue_by_molecular_genetics_method_nominal
    COALESCE(la.lab_3042151_most_recent, 0) AS tau_protein_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_recent, COALESCE(la.lab_3042151_mean_90d, 0) AS tau_protein_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_mean_90d, COALESCE(la.lab_3042151_median_90d, 0) AS tau_protein_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_median_90d, COALESCE(la.lab_3042151_abnormal_flag, 0) AS tau_protein_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_abn, --tau_protein_amyloid_beta_42_peptide_in_cerebral_spinal_fluid

    -- IDs: 1761505, 1617650, 1616613, 3042810, 42868555, 1617024
    COALESCE(la.lab_1761505_most_recent, 0) AS glial_fibrillary_acidic_protein_in_serum_by_immunoassay_recent, COALESCE(la.lab_1761505_mean_90d, 0) AS glial_fibrillary_acidic_protein_in_serum_by_immunoassay_mean_90d, COALESCE(la.lab_1761505_median_90d, 0) AS glial_fibrillary_acidic_protein_in_serum_by_immunoassay_median_90d, COALESCE(la.lab_1761505_abnormal_flag, 0) AS glial_fibrillary_acidic_protein_in_serum_by_immunoassay_abn, --glial_fibrillary_acidic_protein_in_serum_by_immunoassay
    COALESCE(la.lab_1617650_most_recent, 0) AS phosphorylated_tau_181_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_recent, COALESCE(la.lab_1617650_mean_90d, 0) AS phosphorylated_tau_181_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_mean_90d, COALESCE(la.lab_1617650_median_90d, 0) AS phosphorylated_tau_181_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_median_90d, COALESCE(la.lab_1617650_abnormal_flag, 0) AS phosphorylated_tau_181_amyloid_beta_42_peptide_in_cerebral_spinal_fluid_abn, --phosphorylated_tau_181_amyloid_beta_42_peptide_in_cerebral_spinal_fluid
    COALESCE(la.lab_1616613_most_recent, 0) AS glial_fibrillary_acidic_protein_in_plasma_by_immunoassay_recent, COALESCE(la.lab_1616613_mean_90d, 0) AS glial_fibrillary_acidic_protein_in_plasma_by_immunoassay_mean_90d, COALESCE(la.lab_1616613_median_90d, 0) AS glial_fibrillary_acidic_protein_in_plasma_by_immunoassay_median_90d, COALESCE(la.lab_1616613_abnormal_flag, 0) AS glial_fibrillary_acidic_protein_in_plasma_by_immunoassay_abn, --glial_fibrillary_acidic_protein_in_plasma_by_immunoassay
    COALESCE(la.lab_3042810_most_recent, 0) AS amyloid_beta_42_peptide_in_cerebral_spinal_fluid_recent, COALESCE(la.lab_3042810_mean_90d, 0) AS amyloid_beta_42_peptide_in_cerebral_spinal_fluid_mean_90d, COALESCE(la.lab_3042810_median_90d, 0) AS amyloid_beta_42_peptide_in_cerebral_spinal_fluid_median_90d, COALESCE(la.lab_3042810_abnormal_flag, 0) AS amyloid_beta_42_peptide_in_cerebral_spinal_fluid_abn, --amyloid_beta_42_peptide_in_cerebral_spinal_fluid
    COALESCE(la.lab_42868555_most_recent, 0) AS amyloid_beta_40_peptide_in_cerebral_spinal_fluid_recent, COALESCE(la.lab_42868555_mean_90d, 0) AS amyloid_beta_40_peptide_in_cerebral_spinal_fluid_mean_90d, COALESCE(la.lab_42868555_median_90d, 0) AS amyloid_beta_40_peptide_in_cerebral_spinal_fluid_median_90d, COALESCE(la.lab_42868555_abnormal_flag, 0) AS amyloid_beta_40_peptide_in_cerebral_spinal_fluid_abn, --amyloid_beta_40_peptide_in_cerebral_spinal_fluid
    COALESCE(la.lab_1617024_most_recent, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_cerebral_spinal_fluid_recent, COALESCE(la.lab_1617024_mean_90d, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_cerebral_spinal_fluid_mean_90d, COALESCE(la.lab_1617024_median_90d, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_cerebral_spinal_fluid_median_90d, COALESCE(la.lab_1617024_abnormal_flag, 0) AS amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_cerebral_spinal_fluid_abn, --amyloid_beta_42_peptide_amyloid_beta_40_peptide_in_cerebral_spinal_fluid

    -- ==========================================================
    -- 4. PROCEDURE METRICS (180d Count & 90d Presence Flag)
    -- ==========================================================
    -- IDs: 2211329, 2211328, 2211327, 2211332, 2211330
    COALESCE(pr.procedure_count_180d_2211329, 0) AS computed_tomography_head_or_brain_without_contrast_material_followed_by_contrast_materials_and_further_sections_180d_ct, COALESCE(pr.procedure_within_90d_2211329, 0) AS computed_tomography_head_or_brain_without_contrast_material_followed_by_contrast_materials_and_further_sections_90d, --computed_tomography_head_or_brain_without_contrast_material_followed_by_contrast_materials_and_further_sections
    COALESCE(pr.procedure_count_180d_2211328, 0) AS computed_tomography_head_or_brain_with_contrast_materials_180d_ct, COALESCE(pr.procedure_within_90d_2211328, 0) AS computed_tomography_head_or_brain_with_contrast_materials_90d, --computed_tomography_head_or_brain_with_contrast_materials
    COALESCE(pr.procedure_count_180d_2211327, 0) AS computed_tomography_head_or_brain_without_contrast_material_180d_ct, COALESCE(pr.procedure_within_90d_2211327, 0) AS computed_tomography_head_or_brain_without_contrast_material_90d, --computed_tomography_head_or_brain_without_contrast_material
    COALESCE(pr.procedure_count_180d_2211332, 0) AS computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middle_or_inner_ear_without_contrast_material_followed_by_contrast_materials_and_further_sections_180d_ct, COALESCE(pr.procedure_within_90d_2211332, 0) AS computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middle_or_inner_ear_without_contrast_material_followed_by_contrast_materials_and_further_sections_90d, --computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middle_or_inner_ear_without_contrast_material_followed_by_contrast_materials_and_further_sections
    COALESCE(pr.procedure_count_180d_2211330, 0) AS computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middle_or_inner_ear_without_contrast_material_180d_ct, COALESCE(pr.procedure_within_90d_2211330, 0) AS computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middle_or_inner_ear_without_contrast_material_90d, --computed_tomography_orbit_sella_or_posterior_fossa_or_outer_middleOr_inner_ear_without_contrast_material

    -- IDs: 2211353, 2211351, 2211719, 2212018, 2212056, 2212053
    COALESCE(pr.procedure_count_180d_2211353, 0) AS magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material_followed_by_contrast_materials_and_further_sequences_180d_ct, COALESCE(pr.procedure_within_90d_2211353, 0) AS magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material_followed_by_contrast_materials_and_further_sequences_90d, --magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material_followed_by_contrast_materials_and_further_sequences
    COALESCE(pr.procedure_count_180d_2211351, 0) AS magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material_180d_ct, COALESCE(pr.procedure_within_90d_2211351, 0) AS magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material_90d, --magnetic_resonance_eg_proton_imaging_brain_including_brain_stem_without_contrast_material
    COALESCE(pr.procedure_count_180d_2211719, 0) AS magnetic_resonance_spectroscopy_180d_ct, COALESCE(pr.procedure_within_90d_2211719, 0) AS magnetic_resonance_spectroscopy_90d, --magnetic_resonance_spectroscopy
    COALESCE(pr.procedure_count_180d_2212018, 0) AS brain_imaging_pet_metabolic_evaluation_180d_ct, COALESCE(pr.procedure_within_90d_2212018, 0) AS brain_imaging_pet_metabolic_evaluation_90d, --brain_imaging_pet_metabolic_evaluation
    COALESCE(pr.procedure_count_180d_2212056, 0) AS pet_with_concurrently_acquired_ct_for_attenuation_correction_and_anatomical_localization_imaging_limited_area_180d_ct, COALESCE(pr.procedure_within_90d_2212056, 0) AS pet_with_concurrently_acquired_ct_for_attenuation_correction_and_anatomical_localization_imaging_limited_area_90d, --pet_with_concurrently_acquired_ct_for_attenuation_correction_and_anatomical_localization_imaging_limited_area
    COALESCE(pr.procedure_count_180d_2212053, 0) AS pet_imaging_limited_area_180d_ct, COALESCE(pr.procedure_within_90d_2212053, 0) AS pet_imaging_limited_area_90d --pet_imaging_limited_area

FROM CogScoreWithDelta csr
LEFT JOIN EligibleCohort ec 
    on csr.person_id = ec.person_id
LEFT JOIN LabsAggPerTest la
    ON csr.person_id = la.person_id 
    AND csr.measurement_date = la.test_date
LEFT JOIN ProceduresPerTest pr
    ON csr.person_id = pr.person_id
    AND csr.measurement_date = pr.test_date
JOIN Demographics d
    ON ec.person_id = d.person_id
LEFT JOIN DrugExposureWide dew
    ON ec.person_id = dew.person_id
    AND csr.measurement_date = dew.test_date

ORDER BY ec.person_id, csr.measurement_date
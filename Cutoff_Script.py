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

ObsPeriod AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM observation_period
    WHERE observation_period_end_date IS NOT NULL
    GROUP BY person_id
),

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

TestCutoffs AS (
    SELECT 'minicog' AS scale, 3.0  AS cutoff, 5.0  AS upper_bound
    UNION ALL SELECT 'mmse',   24.0,            30.0
    UNION ALL SELECT 'moca',   26.0,            30.0
),

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
        AND m.measurement_date <= ec.index_date + INTERVAL 730 DAY
    GROUP BY
        m.person_id,
        m.measurement_date,
        ml.scale
),

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
            WHEN prev_score IS NULL          THEN 'BASELINE'
            WHEN cutoff_score > prev_score   THEN 'IMPROVED'
            WHEN cutoff_score < prev_score   THEN 'WORSE'
            ELSE                                  'STABLE'
        END AS trajectory
    FROM CogScoreRanked
    WHERE prev_score IS NOT NULL
),

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

drug_cohort_collapsed AS (
    SELECT
        dc.person_id,
        dc.test_date,
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
        dc.test_date,
        dc.drug_concept_id,
        dh.ingredient_level,
        dc.index_date
),

Demographics AS (
    SELECT
        p.person_id,
        CASE
            WHEN p.year_of_birth IS NULL THEN NULL
            ELSE YEAR(cd.index_date) - p.year_of_birth
        END AS age_at_index,
        CASE WHEN LOWER(g.concept_name) = 'male'                                      THEN 1 ELSE 0 END AS sex_male,
        CASE WHEN LOWER(g.concept_name) = 'female'                                    THEN 1 ELSE 0 END AS sex_female,
        CASE WHEN LOWER(g.concept_name) = 'no matching concept' OR g.concept_name IS NULL THEN 1 ELSE 0 END AS sex_unknown,
        CASE WHEN LOWER(r.concept_name) = 'white'                                     THEN 1 ELSE 0 END AS race_white,
        CASE WHEN LOWER(r.concept_name) = 'black or african american'                 THEN 1 ELSE 0 END AS race_black_or_african_american,
        CASE WHEN LOWER(r.concept_name) = 'asian'                                     THEN 1 ELSE 0 END AS race_asian,
        CASE WHEN LOWER(r.concept_name) = 'american indian or alaska native'          THEN 1 ELSE 0 END AS race_american_indian_or_alaska_native,
        CASE WHEN LOWER(r.concept_name) = 'native hawaiian or other pacific islander' THEN 1 ELSE 0 END AS race_native_hawaiian_or_other_pacific_islander,
        CASE WHEN LOWER(r.concept_name) = 'other race'                                THEN 1 ELSE 0 END AS race_other,
        CASE WHEN LOWER(r.concept_name) = 'no matching concept' OR r.concept_name IS NULL THEN 1 ELSE 0 END AS race_unknown,
        CASE WHEN LOWER(e.concept_name) = 'not hispanic or latino'                    THEN 1 ELSE 0 END AS ethnicity_not_hispanic_or_latino,
        CASE WHEN LOWER(e.concept_name) = 'hispanic or latino'                        THEN 1 ELSE 0 END AS ethnicity_hispanic_or_latino,
        CASE WHEN LOWER(e.concept_name) = 'no matching concept' OR e.concept_name IS NULL THEN 1 ELSE 0 END AS ethnicity_unknown
    FROM person p
    JOIN EligibleCohort cd
        ON p.person_id = cd.person_id
    LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
    LEFT JOIN concept r ON p.race_concept_id = r.concept_id
    LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
)

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
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.cumulative_days_exposed END), 0) AS haloperidol_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_0_30d END), 0)          AS haloperidol_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_31_90d END), 0)         AS haloperidol_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%'     THEN dcc.exposed_91_180d END), 0)        AS haloperidol_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.cumulative_days_exposed END), 0) AS lecanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_0_30d END), 0)           AS lecanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_31_90d END), 0)          AS lecanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%'       THEN dcc.exposed_91_180d END), 0)         AS lecanemab_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.cumulative_days_exposed END), 0) AS donanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_0_30d END), 0)           AS donanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_31_90d END), 0)          AS donanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%'       THEN dcc.exposed_91_180d END), 0)         AS donanemab_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.cumulative_days_exposed END), 0) AS brexpiprazole_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_0_30d END), 0)           AS brexpiprazole_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_31_90d END), 0)          AS brexpiprazole_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%'   THEN dcc.exposed_91_180d END), 0)         AS brexpiprazole_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.cumulative_days_exposed END), 0) AS memantine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_0_30d END), 0)           AS memantine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_31_90d END), 0)          AS memantine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%'       THEN dcc.exposed_91_180d END), 0)         AS memantine_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.cumulative_days_exposed END), 0) AS donepezil_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_0_30d END), 0)           AS donepezil_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_31_90d END), 0)          AS donepezil_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%'       THEN dcc.exposed_91_180d END), 0)         AS donepezil_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.cumulative_days_exposed END), 0) AS rivastigmine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_0_30d END), 0)           AS rivastigmine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_31_90d END), 0)          AS rivastigmine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%'    THEN dcc.exposed_91_180d END), 0)         AS rivastigmine_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.cumulative_days_exposed END), 0) AS galantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_0_30d END), 0)           AS galantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_31_90d END), 0)          AS galantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%'     THEN dcc.exposed_91_180d END), 0)         AS galantamine_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.cumulative_days_exposed END), 0) AS benzgalantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_0_30d END), 0)           AS benzgalantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_31_90d END), 0)          AS benzgalantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_91_180d END), 0)         AS benzgalantamine_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.cumulative_days_exposed END), 0) AS suvorexant_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_0_30d END), 0)           AS suvorexant_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_31_90d END), 0)          AS suvorexant_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%'      THEN dcc.exposed_91_180d END), 0)         AS suvorexant_91_180d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.cumulative_days_exposed END), 0) AS risperidone_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_0_30d END), 0)           AS risperidone_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_31_90d END), 0)          AS risperidone_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_91_180d END), 0)         AS risperidone_91_180d
FROM EligibleCohort ec
JOIN Demographics d
    ON ec.person_id = d.person_id
JOIN CogScoreWithDelta csr
    ON ec.person_id = csr.person_id
JOIN drug_cohort_collapsed dcc
    ON ec.person_id = dcc.person_id
    AND dcc.test_date = csr.measurement_date
LEFT JOIN drug_hierarchy dh
    ON dcc.drug_concept_id = dh.drug_concept_id
GROUP BY
    ec.person_id,
    ec.index_date,
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
    csr.measurement_date,
    csr.scale,
    csr.cutoff_score,
    csr.prev_test_date,
    csr.prev_score,
    csr.score_delta_from_last,
    csr.trajectory
ORDER BY ec.person_id, csr.measurement_date
"""
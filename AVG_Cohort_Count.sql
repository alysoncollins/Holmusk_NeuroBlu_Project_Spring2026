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

-- One observation period row per person using the latest end date
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
    WHERE DATEDIFF(DAY, cd.index_date, op.observation_period_end_date) >= 180
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
        AND m.measurement_date <= DATEADD(DAY, 730, ec.index_date)
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
            WHEN prev_score IS NULL          THEN 'BASELINE'
            WHEN cutoff_score > prev_score   THEN 'IMPROVED'
            WHEN cutoff_score < prev_score   THEN 'WORSE'
            ELSE                                  'STABLE'
        END AS trajectory
    FROM CogScoreRanked
    WHERE prev_score IS NOT NULL
),

-- Drug exposure windows scoped to eligible persons only
drug_cohort AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        ec.index_date,
        csr.measurement_date AS test_date,
        (DATEDIFF(DAY,
            de.drug_exposure_start_date,
            COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
        ) + 1) AS cumulative_days_exposed,
        CASE
            WHEN de.drug_exposure_start_date <= csr.measurement_date
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= DATEADD(DAY, -30, csr.measurement_date)
            THEN 1 ELSE 0
        END AS exposed_0_30d,
        CASE
            WHEN de.drug_exposure_start_date <= DATEADD(DAY, -31, csr.measurement_date)
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= DATEADD(DAY, -90, csr.measurement_date)
            THEN 1 ELSE 0
        END AS exposed_31_90d,
        CASE
            WHEN de.drug_exposure_start_date <= DATEADD(DAY, -91, csr.measurement_date)
             AND COALESCE(de.drug_exposure_end_date, de.drug_exposure_start_date)
                 >= DATEADD(DAY, -180, csr.measurement_date)
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
      AND m.value_as_number IS NOT NULL
),

-- Row-number + lag to identify most-recent value and its predecessor
LabsRanked AS (
    SELECT
        person_id,
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

-- Most-recent row per person per concept
LabsMostRecent AS (
    SELECT
        csr.person_id,
        csr.measurement_date AS test_date,
        lc.measurement_concept_id,
        lc.value_as_number as most_recent_score,
        lc.measurement_datetime,

        -- previous lab BEFORE this test_date
        LAG(lc.value_as_number) OVER (
            PARTITION BY csr.person_id, lc.measurement_concept_id, csr.measurement_date
            ORDER BY lc.measurement_datetime
        ) AS previous_value

    FROM CogScoreWithDelta csr
    JOIN LabsCohort lc
        ON lc.person_id = csr.person_id
       AND lc.measurement_datetime <= csr.measurement_date
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
       AND lc.measurement_datetime BETWEEN DATEADD(DAY, -90, csr.measurement_date)
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
        p.procedure_concept_id,

        -- CONCEPT: 2211329 computed tomography, head or brain; without contrast material, followed by contrast material(s) and further sections
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211329,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211329,

        -- CONCEPT: 2211328 computed tomography, head or brain; with contrast material(s)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211328,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211328,

        -- CONCEPT: 2211327 computed tomography, head or brain; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211327,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211327,

        -- CONCEPT: 2211332 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material, followed by contrast material(s) and further sections  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211332,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211332,

        -- CONCEPT: 2211330 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211330,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211330,

        -- CONCEPT: 2211353 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material, followed by contrast material(s) and further sequences 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211353,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211353,

        -- CONCEPT: 2211351 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211351,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211351,

        -- CONCEPT: 2211719 magnetic resonance spectroscopy 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2211719,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211719,

        -- CONCEPT: 2212018 brain imaging, positron emission tomography (pet); metabolic evaluation   
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212018,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212018,

        -- CONCEPT: 2212056 positron emission tomography (pet) with concurrently acquired computed tomography (ct) for attenuation correction and anatomical localization imaging; limited area (eg, chest, head/neck)    
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212056,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212056,

        -- CONCEPT: 2212053 positron emission tomography (pet) imaging; limited area (eg, chest, head/neck)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date BETWEEN DATEADD(DAY, -180, csr.measurement_date)
                                  AND csr.measurement_date
            THEN p.procedure_date
        END) AS procedure_count_180d_2212053,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date BETWEEN DATEADD(DAY, -90, csr.measurement_date)
                                  AND csr.measurement_date
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212053

    FROM CogScoreWithDelta csr
    LEFT JOIN procedure_occurrence p
        ON p.person_id = csr.person_id
    GROUP BY csr.person_id, csr.measurement_date, p.procedure_concept_id
),

DrugExposures AS (
    -- Groups by person_id and test_date to guarantee 1 row per test
    SELECT 
        dcc.person_id,
        dcc.test_date,
        
        MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS halo_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_0_30d ELSE 0 END) AS halo_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_31_90d ELSE 0 END) AS halo_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_91_180d ELSE 0 END) AS halo_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS leca_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_0_30d ELSE 0 END) AS leca_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_31_90d ELSE 0 END) AS leca_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_91_180d ELSE 0 END) AS leca_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS dona_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_0_30d ELSE 0 END) AS dona_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_31_90d ELSE 0 END) AS dona_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_91_180d ELSE 0 END) AS dona_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS brex_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_0_30d ELSE 0 END) AS brex_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_31_90d ELSE 0 END) AS brex_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_91_180d ELSE 0 END) AS brex_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS mema_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_0_30d ELSE 0 END) AS mema_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_31_90d ELSE 0 END) AS mema_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_91_180d ELSE 0 END) AS mema_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS done_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_0_30d ELSE 0 END) AS done_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_31_90d ELSE 0 END) AS done_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_91_180d ELSE 0 END) AS done_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS riva_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_0_30d ELSE 0 END) AS riva_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_31_90d ELSE 0 END) AS riva_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_91_180d ELSE 0 END) AS riva_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS gala_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_0_30d ELSE 0 END) AS gala_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_31_90d ELSE 0 END) AS gala_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_91_180d ELSE 0 END) AS gala_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS benz_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_0_30d ELSE 0 END) AS benz_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_31_90d ELSE 0 END) AS benz_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_91_180d ELSE 0 END) AS benz_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS suvo_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_0_30d ELSE 0 END) AS suvo_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_31_90d ELSE 0 END) AS suvo_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_91_180d ELSE 0 END) AS suvo_91_180d,

        MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.cumulative_days_exposed ELSE 0 END) AS risp_days,
        MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_0_30d ELSE 0 END) AS risp_0_30d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_31_90d ELSE 0 END) AS risp_31_90d,
        MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_91_180d ELSE 0 END) AS risp_91_180d

    FROM drug_cohort_collapsed dcc
    LEFT JOIN drug_hierarchy dh
        ON dcc.drug_concept_id = dh.drug_concept_id
    GROUP BY dcc.person_id, dcc.test_date
),

-- Defensive CTEs: Forces exactly 1 row per person (or person+date)
UniqueCohort AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY person_id ORDER BY person_id) as rn
        FROM EligibleCohort
    ) WHERE rn = 1
),
UniqueDemographics AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY person_id ORDER BY person_id) as rn
        FROM Demographics
    ) WHERE rn = 1
),
UniqueLabs AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY person_id, test_date ORDER BY test_date) as rn
        FROM LabsAggPerTest
    ) WHERE rn = 1
),
UniqueProcedures AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY person_id, test_date ORDER BY test_date) as rn
        FROM ProceduresPerTest
    ) WHERE rn = 1
)

SELECT
    -- Row count
    COUNT(*) AS total_rows,

    -- Core score/trajectory fields
    COUNT(CASE WHEN csr.cutoff_score <> 0 THEN 1 END) AS cutoff_score_nonzero,
    COUNT(CASE WHEN csr.score_delta_from_last <> 0 THEN 1 END) AS score_delta_nonzero,
    COUNT(CASE WHEN csr.prev_score <> 0 THEN 1 END) AS prev_score_nonzero,

    -- Demographics
    COUNT(CASE WHEN d.age_at_index <> 0 THEN 1 END) AS age_at_index_nonzero,
    COUNT(CASE WHEN d.sex_male <> 0 THEN 1 END) AS sex_male_nonzero,
    COUNT(CASE WHEN d.sex_female <> 0 THEN 1 END) AS sex_female_nonzero,
    COUNT(CASE WHEN d.sex_unknown <> 0 THEN 1 END) AS sex_unknown_nonzero,
    COUNT(CASE WHEN d.race_white <> 0 THEN 1 END) AS race_white_nonzero,
    COUNT(CASE WHEN d.race_black_or_african_american <> 0 THEN 1 END) AS race_black_nonzero,
    COUNT(CASE WHEN d.race_asian <> 0 THEN 1 END) AS race_asian_nonzero,
    COUNT(CASE WHEN d.race_american_indian_or_alaska_native <> 0 THEN 1 END) AS race_aian_nonzero,
    COUNT(CASE WHEN d.race_native_hawaiian_or_other_pacific_islander <> 0 THEN 1 END) AS race_nhopi_nonzero,
    COUNT(CASE WHEN d.race_other <> 0 THEN 1 END) AS race_other_nonzero,
    COUNT(CASE WHEN d.race_unknown <> 0 THEN 1 END) AS race_unknown_nonzero,
    COUNT(CASE WHEN d.ethnicity_not_hispanic_or_latino <> 0 THEN 1 END) AS eth_not_hispanic_nonzero,
    COUNT(CASE WHEN d.ethnicity_hispanic_or_latino <> 0 THEN 1 END) AS eth_hispanic_nonzero,
    COUNT(CASE WHEN d.ethnicity_unknown <> 0 THEN 1 END) AS eth_unknown_nonzero,

    -- Drugs
    COUNT(CASE WHEN de.halo_days <> 0 THEN 1 END) AS haloperidol_days_nonzero,
    COUNT(CASE WHEN de.halo_0_30d <> 0 THEN 1 END) AS haloperidol_0_30d_nonzero,
    COUNT(CASE WHEN de.halo_31_90d <> 0 THEN 1 END) AS haloperidol_31_90d_nonzero,
    COUNT(CASE WHEN de.halo_91_180d <> 0 THEN 1 END) AS haloperidol_91_180d_nonzero,

    COUNT(CASE WHEN de.leca_days <> 0 THEN 1 END) AS lecanemab_days_nonzero,
    COUNT(CASE WHEN de.leca_0_30d <> 0 THEN 1 END) AS lecanemab_0_30d_nonzero,
    COUNT(CASE WHEN de.leca_31_90d <> 0 THEN 1 END) AS lecanemab_31_90d_nonzero,
    COUNT(CASE WHEN de.leca_91_180d <> 0 THEN 1 END) AS lecanemab_91_180d_nonzero,

    COUNT(CASE WHEN de.dona_days <> 0 THEN 1 END) AS donanemab_days_nonzero,
    COUNT(CASE WHEN de.dona_0_30d <> 0 THEN 1 END) AS donanemab_0_30d_nonzero,
    COUNT(CASE WHEN de.dona_31_90d <> 0 THEN 1 END) AS donanemab_31_90d_nonzero,
    COUNT(CASE WHEN de.dona_91_180d <> 0 THEN 1 END) AS donanemab_91_180d_nonzero,

    COUNT(CASE WHEN de.brex_days <> 0 THEN 1 END) AS brexpiprazole_days_nonzero,
    COUNT(CASE WHEN de.brex_0_30d <> 0 THEN 1 END) AS brexpiprazole_0_30d_nonzero,
    COUNT(CASE WHEN de.brex_31_90d <> 0 THEN 1 END) AS brexpiprazole_31_90d_nonzero,
    COUNT(CASE WHEN de.brex_91_180d <> 0 THEN 1 END) AS brexpiprazole_91_180d_nonzero,

    COUNT(CASE WHEN de.mema_days <> 0 THEN 1 END) AS memantine_days_nonzero,
    COUNT(CASE WHEN de.mema_0_30d <> 0 THEN 1 END) AS memantine_0_30d_nonzero,
    COUNT(CASE WHEN de.mema_31_90d <> 0 THEN 1 END) AS memantine_31_90d_nonzero,
    COUNT(CASE WHEN de.mema_91_180d <> 0 THEN 1 END) AS memantine_91_180d_nonzero,

    COUNT(CASE WHEN de.done_days <> 0 THEN 1 END) AS donepezil_days_nonzero,
    COUNT(CASE WHEN de.done_0_30d <> 0 THEN 1 END) AS donepezil_0_30d_nonzero,
    COUNT(CASE WHEN de.done_31_90d <> 0 THEN 1 END) AS donepezil_31_90d_nonzero,
    COUNT(CASE WHEN de.done_91_180d <> 0 THEN 1 END) AS donepezil_91_180d_nonzero,

    COUNT(CASE WHEN de.riva_days <> 0 THEN 1 END) AS rivastigmine_days_nonzero,
    COUNT(CASE WHEN de.riva_0_30d <> 0 THEN 1 END) AS rivastigmine_0_30d_nonzero,
    COUNT(CASE WHEN de.riva_31_90d <> 0 THEN 1 END) AS rivastigmine_31_90d_nonzero,
    COUNT(CASE WHEN de.riva_91_180d <> 0 THEN 1 END) AS rivastigmine_91_180d_nonzero,

    COUNT(CASE WHEN de.gala_days <> 0 THEN 1 END) AS galantamine_days_nonzero,
    COUNT(CASE WHEN de.gala_0_30d <> 0 THEN 1 END) AS galantamine_0_30d_nonzero,
    COUNT(CASE WHEN de.gala_31_90d <> 0 THEN 1 END) AS galantamine_31_90d_nonzero,
    COUNT(CASE WHEN de.gala_91_180d <> 0 THEN 1 END) AS galantamine_91_180d_nonzero,

    COUNT(CASE WHEN de.benz_days <> 0 THEN 1 END) AS benzgalantamine_days_nonzero,
    COUNT(CASE WHEN de.benz_0_30d <> 0 THEN 1 END) AS benzgalantamine_0_30d_nonzero,
    COUNT(CASE WHEN de.benz_31_90d <> 0 THEN 1 END) AS benzgalantamine_31_90d_nonzero,
    COUNT(CASE WHEN de.benz_91_180d <> 0 THEN 1 END) AS benzgalantamine_91_180d_nonzero,

    COUNT(CASE WHEN de.suvo_days <> 0 THEN 1 END) AS suvorexant_days_nonzero,
    COUNT(CASE WHEN de.suvo_0_30d <> 0 THEN 1 END) AS suvorexant_0_30d_nonzero,
    COUNT(CASE WHEN de.suvo_31_90d <> 0 THEN 1 END) AS suvorexant_31_90d_nonzero,
    COUNT(CASE WHEN de.suvo_91_180d <> 0 THEN 1 END) AS suvorexant_91_180d_nonzero,

    COUNT(CASE WHEN de.risp_days <> 0 THEN 1 END) AS risperidone_days_nonzero,
    COUNT(CASE WHEN de.risp_0_30d <> 0 THEN 1 END) AS risperidone_0_30d_nonzero,
    COUNT(CASE WHEN de.risp_31_90d <> 0 THEN 1 END) AS risperidone_31_90d_nonzero,
    COUNT(CASE WHEN de.risp_91_180d <> 0 THEN 1 END) AS risperidone_91_180d_nonzero,

    -- Labs
    COUNT(CASE WHEN COALESCE(la.lab_3003722_most_recent, 0) <> 0 THEN 1 END) AS lab_3003722_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3003722_mean_90d, 0) <> 0 THEN 1 END) AS lab_3003722_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3003722_median_90d, 0) <> 0 THEN 1 END) AS lab_3003722_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3003722_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3003722_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3050174_most_recent, 0) <> 0 THEN 1 END) AS lab_3050174_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3050174_mean_90d, 0) <> 0 THEN 1 END) AS lab_3050174_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3050174_median_90d, 0) <> 0 THEN 1 END) AS lab_3050174_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3050174_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3050174_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3043102_most_recent, 0) <> 0 THEN 1 END) AS lab_3043102_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3043102_mean_90d, 0) <> 0 THEN 1 END) AS lab_3043102_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3043102_median_90d, 0) <> 0 THEN 1 END) AS lab_3043102_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3043102_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3043102_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_42868556_most_recent, 0) <> 0 THEN 1 END) AS lab_42868556_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868556_mean_90d, 0) <> 0 THEN 1 END) AS lab_42868556_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868556_median_90d, 0) <> 0 THEN 1 END) AS lab_42868556_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868556_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_42868556_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1469579_most_recent, 0) <> 0 THEN 1 END) AS lab_1469579_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1469579_mean_90d, 0) <> 0 THEN 1 END) AS lab_1469579_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1469579_median_90d, 0) <> 0 THEN 1 END) AS lab_1469579_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1469579_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1469579_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1092155_most_recent, 0) <> 0 THEN 1 END) AS lab_1092155_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1092155_mean_90d, 0) <> 0 THEN 1 END) AS lab_1092155_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1092155_median_90d, 0) <> 0 THEN 1 END) AS lab_1092155_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1092155_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1092155_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1259491_most_recent, 0) <> 0 THEN 1 END) AS lab_1259491_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1259491_mean_90d, 0) <> 0 THEN 1 END) AS lab_1259491_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1259491_median_90d, 0) <> 0 THEN 1 END) AS lab_1259491_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1259491_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1259491_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3011498_most_recent, 0) <> 0 THEN 1 END) AS lab_3011498_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3011498_mean_90d, 0) <> 0 THEN 1 END) AS lab_3011498_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3011498_median_90d, 0) <> 0 THEN 1 END) AS lab_3011498_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3011498_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3011498_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3029139_most_recent, 0) <> 0 THEN 1 END) AS lab_3029139_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3029139_mean_90d, 0) <> 0 THEN 1 END) AS lab_3029139_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3029139_median_90d, 0) <> 0 THEN 1 END) AS lab_3029139_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3029139_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3029139_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3042151_most_recent, 0) <> 0 THEN 1 END) AS lab_3042151_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042151_mean_90d, 0) <> 0 THEN 1 END) AS lab_3042151_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042151_median_90d, 0) <> 0 THEN 1 END) AS lab_3042151_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042151_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3042151_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1761505_most_recent, 0) <> 0 THEN 1 END) AS lab_1761505_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1761505_mean_90d, 0) <> 0 THEN 1 END) AS lab_1761505_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1761505_median_90d, 0) <> 0 THEN 1 END) AS lab_1761505_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1761505_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1761505_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1617650_most_recent, 0) <> 0 THEN 1 END) AS lab_1617650_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617650_mean_90d, 0) <> 0 THEN 1 END) AS lab_1617650_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617650_median_90d, 0) <> 0 THEN 1 END) AS lab_1617650_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617650_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1617650_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1616613_most_recent, 0) <> 0 THEN 1 END) AS lab_1616613_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1616613_mean_90d, 0) <> 0 THEN 1 END) AS lab_1616613_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1616613_median_90d, 0) <> 0 THEN 1 END) AS lab_1616613_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1616613_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1616613_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_3042810_most_recent, 0) <> 0 THEN 1 END) AS lab_3042810_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042810_mean_90d, 0) <> 0 THEN 1 END) AS lab_3042810_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042810_median_90d, 0) <> 0 THEN 1 END) AS lab_3042810_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_3042810_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_3042810_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_42868555_most_recent, 0) <> 0 THEN 1 END) AS lab_42868555_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868555_mean_90d, 0) <> 0 THEN 1 END) AS lab_42868555_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868555_median_90d, 0) <> 0 THEN 1 END) AS lab_42868555_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_42868555_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_42868555_abn_nonzero,

    COUNT(CASE WHEN COALESCE(la.lab_1617024_most_recent, 0) <> 0 THEN 1 END) AS lab_1617024_recent_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617024_mean_90d, 0) <> 0 THEN 1 END) AS lab_1617024_mean_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617024_median_90d, 0) <> 0 THEN 1 END) AS lab_1617024_median_nonzero,
    COUNT(CASE WHEN COALESCE(la.lab_1617024_abnormal_flag, 0) <> 0 THEN 1 END) AS lab_1617024_abn_nonzero,

    -- Procedures
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211329, 0) <> 0 THEN 1 END) AS pr_2211329_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211329, 0) <> 0 THEN 1 END) AS pr_2211329_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211328, 0) <> 0 THEN 1 END) AS pr_2211328_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211328, 0) <> 0 THEN 1 END) AS pr_2211328_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211327, 0) <> 0 THEN 1 END) AS pr_2211327_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211327, 0) <> 0 THEN 1 END) AS pr_2211327_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211332, 0) <> 0 THEN 1 END) AS pr_2211332_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211332, 0) <> 0 THEN 1 END) AS pr_2211332_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211330, 0) <> 0 THEN 1 END) AS pr_2211330_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211330, 0) <> 0 THEN 1 END) AS pr_2211330_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211353, 0) <> 0 THEN 1 END) AS pr_2211353_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211353, 0) <> 0 THEN 1 END) AS pr_2211353_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211351, 0) <> 0 THEN 1 END) AS pr_2211351_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211351, 0) <> 0 THEN 1 END) AS pr_2211351_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2211719, 0) <> 0 THEN 1 END) AS pr_2211719_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2211719, 0) <> 0 THEN 1 END) AS pr_2211719_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2212018, 0) <> 0 THEN 1 END) AS pr_2212018_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2212018, 0) <> 0 THEN 1 END) AS pr_2212018_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2212056, 0) <> 0 THEN 1 END) AS pr_2212056_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2212056, 0) <> 0 THEN 1 END) AS pr_2212056_90d_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_count_180d_2212053, 0) <> 0 THEN 1 END) AS pr_2212053_ct_nonzero,
    COUNT(CASE WHEN COALESCE(pr.procedure_within_90d_2212053, 0) <> 0 THEN 1 END) AS pr_2212053_90d_nonzero

FROM CogScoreWithDelta csr
-- Using our defensive CTEs in the joins instead of the raw tables
LEFT JOIN UniqueCohort ec 
    ON csr.person_id = ec.person_id
LEFT JOIN UniqueLabs la
    ON csr.person_id = la.person_id 
    AND csr.measurement_date = la.test_date
LEFT JOIN UniqueProcedures pr
    ON csr.person_id = pr.person_id
    AND csr.measurement_date = pr.test_date
JOIN UniqueDemographics d
    ON ec.person_id = d.person_id
LEFT JOIN DrugExposures de 
    ON csr.person_id = de.person_id 
    AND csr.measurement_date = de.test_date;
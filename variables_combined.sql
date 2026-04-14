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
    WHERE DATEDIFF(DAY, cd.index_date, op.observation_period_end_date) >= 180
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
            --AND m.value_as_number IS NOT NULL
            --AND m.measurement_date >= cd.index_date
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
        (DATEDIFF(DAY,
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
),

-- ─────────────────────────────────────────────────────────────────────────────
-- LAB CTEs (scoped to EligibleCohort patients only)
-- ─────────────────────────────────────────────────────────────────────────────

-- Raw lab measurements for the target concept IDs, eligible patients only
LabsCohort AS (
    SELECT
        m.person_id,
        m.measurement_id,
        m.measurement_concept_id,
        m.measurement_datetime,
        m.value_as_number
    FROM measurement m
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

-- Most-recent row per patient per concept
LabsMostRecent AS (
    SELECT
        person_id,
        measurement_concept_id,
        value_as_number      AS most_recent_score,
        previous_score,
        previous_score_datetime,
        measurement_datetime AS most_recent_datetime
    FROM LabsRanked
    WHERE rn = 1
),

-- Rolling 90-day mean/median anchored to each patient's most-recent measurement
LabsRollingStats AS (
    SELECT
        lc.person_id,
        lc.measurement_concept_id,
        AVG(lc.value_as_number)                                              AS rolling_mean_90d,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.value_as_number)     AS rolling_median_90d,
        COUNT(*)                                                             AS measurement_count_90d
    FROM LabsCohort lc
    INNER JOIN LabsMostRecent mr
        ON  lc.person_id              = mr.person_id
        AND lc.measurement_concept_id = mr.measurement_concept_id
    WHERE lc.measurement_datetime
          BETWEEN mr.most_recent_datetime - INTERVAL 90 DAYS
              AND mr.most_recent_datetime
    GROUP BY lc.person_id, lc.measurement_concept_id
),

-- Abnormal flag for the most-recent measurement against reference range
LabsFlag AS (
    SELECT
        lr.person_id,
        lr.measurement_concept_id,
        CASE
            WHEN m.range_low IS NULL AND m.range_high IS NULL THEN NULL
            WHEN lr.value_as_number < m.range_low             THEN 1
            WHEN lr.value_as_number > m.range_high            THEN 1
            ELSE 0
        END AS abnormal_flag
    FROM LabsRanked lr
    INNER JOIN measurement m
        ON  lr.person_id              = m.person_id
        AND lr.measurement_concept_id = m.measurement_concept_id
        AND lr.measurement_datetime   = m.measurement_datetime
    WHERE lr.rn = 1
),

-- Collapse all lab metrics to one wide row per patient via conditional aggregation
-- Each concept_id becomes a column group: most_recent, previous, mean_90d, median_90d, abnormal_flag
-- Rename column aliases below if friendlier concept names are preferred over concept IDs
LabsAgg AS (
    SELECT
        mr.person_id,

        -- Concept 3003722
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN mr.most_recent_score   END) AS lab_3003722_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN mr.previous_score       END) AS lab_3003722_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN rs.rolling_mean_90d     END) AS lab_3003722_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN rs.rolling_median_90d   END) AS lab_3003722_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3003722  THEN lf.abnormal_flag        END) AS lab_3003722_abnormal_flag,

        -- Concept 3050174
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN mr.most_recent_score   END) AS lab_3050174_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN mr.previous_score       END) AS lab_3050174_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN rs.rolling_mean_90d     END) AS lab_3050174_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN rs.rolling_median_90d   END) AS lab_3050174_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3050174  THEN lf.abnormal_flag        END) AS lab_3050174_abnormal_flag,

        -- Concept 3043102
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN mr.most_recent_score   END) AS lab_3043102_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN mr.previous_score       END) AS lab_3043102_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN rs.rolling_mean_90d     END) AS lab_3043102_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN rs.rolling_median_90d   END) AS lab_3043102_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3043102  THEN lf.abnormal_flag        END) AS lab_3043102_abnormal_flag,

        -- Concept 42868556
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN mr.most_recent_score   END) AS lab_42868556_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN mr.previous_score       END) AS lab_42868556_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN rs.rolling_mean_90d     END) AS lab_42868556_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN rs.rolling_median_90d   END) AS lab_42868556_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868556 THEN lf.abnormal_flag        END) AS lab_42868556_abnormal_flag,

        -- Concept 1469579
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN mr.most_recent_score   END) AS lab_1469579_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN mr.previous_score       END) AS lab_1469579_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN rs.rolling_mean_90d     END) AS lab_1469579_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN rs.rolling_median_90d   END) AS lab_1469579_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1469579  THEN lf.abnormal_flag        END) AS lab_1469579_abnormal_flag,

        -- Concept 1092155
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN mr.most_recent_score   END) AS lab_1092155_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN mr.previous_score       END) AS lab_1092155_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN rs.rolling_mean_90d     END) AS lab_1092155_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN rs.rolling_median_90d   END) AS lab_1092155_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1092155  THEN lf.abnormal_flag        END) AS lab_1092155_abnormal_flag,

        -- Concept 1259491
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN mr.most_recent_score   END) AS lab_1259491_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN mr.previous_score       END) AS lab_1259491_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN rs.rolling_mean_90d     END) AS lab_1259491_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN rs.rolling_median_90d   END) AS lab_1259491_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1259491  THEN lf.abnormal_flag        END) AS lab_1259491_abnormal_flag,

        -- Concept 3011498
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN mr.most_recent_score   END) AS lab_3011498_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN mr.previous_score       END) AS lab_3011498_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN rs.rolling_mean_90d     END) AS lab_3011498_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN rs.rolling_median_90d   END) AS lab_3011498_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3011498  THEN lf.abnormal_flag        END) AS lab_3011498_abnormal_flag,

        -- Concept 3029139
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN mr.most_recent_score   END) AS lab_3029139_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN mr.previous_score       END) AS lab_3029139_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN rs.rolling_mean_90d     END) AS lab_3029139_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN rs.rolling_median_90d   END) AS lab_3029139_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3029139  THEN lf.abnormal_flag        END) AS lab_3029139_abnormal_flag,

        -- Concept 3042151
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN mr.most_recent_score   END) AS lab_3042151_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN mr.previous_score       END) AS lab_3042151_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN rs.rolling_mean_90d     END) AS lab_3042151_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN rs.rolling_median_90d   END) AS lab_3042151_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042151  THEN lf.abnormal_flag        END) AS lab_3042151_abnormal_flag,

        -- Concept 1761505
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN mr.most_recent_score   END) AS lab_1761505_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN mr.previous_score       END) AS lab_1761505_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN rs.rolling_mean_90d     END) AS lab_1761505_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN rs.rolling_median_90d   END) AS lab_1761505_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1761505  THEN lf.abnormal_flag        END) AS lab_1761505_abnormal_flag,

        -- Concept 1617650
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN mr.most_recent_score   END) AS lab_1617650_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN mr.previous_score       END) AS lab_1617650_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN rs.rolling_mean_90d     END) AS lab_1617650_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN rs.rolling_median_90d   END) AS lab_1617650_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617650  THEN lf.abnormal_flag        END) AS lab_1617650_abnormal_flag,

        -- Concept 1616613
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN mr.most_recent_score   END) AS lab_1616613_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN mr.previous_score       END) AS lab_1616613_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN rs.rolling_mean_90d     END) AS lab_1616613_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN rs.rolling_median_90d   END) AS lab_1616613_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1616613  THEN lf.abnormal_flag        END) AS lab_1616613_abnormal_flag,

        -- Concept 3042810
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN mr.most_recent_score   END) AS lab_3042810_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN mr.previous_score       END) AS lab_3042810_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN rs.rolling_mean_90d     END) AS lab_3042810_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN rs.rolling_median_90d   END) AS lab_3042810_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 3042810  THEN lf.abnormal_flag        END) AS lab_3042810_abnormal_flag,

        -- Concept 42868555
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN mr.most_recent_score   END) AS lab_42868555_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN mr.previous_score       END) AS lab_42868555_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN rs.rolling_mean_90d     END) AS lab_42868555_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN rs.rolling_median_90d   END) AS lab_42868555_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 42868555 THEN lf.abnormal_flag        END) AS lab_42868555_abnormal_flag,

        -- Concept 1617024
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN mr.most_recent_score   END) AS lab_1617024_most_recent,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN mr.previous_score       END) AS lab_1617024_previous,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN rs.rolling_mean_90d     END) AS lab_1617024_mean_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN rs.rolling_median_90d   END) AS lab_1617024_median_90d,
        MAX(CASE WHEN mr.measurement_concept_id = 1617024  THEN lf.abnormal_flag        END) AS lab_1617024_abnormal_flag

    FROM LabsMostRecent mr
    LEFT JOIN LabsRollingStats rs
        ON  mr.person_id              = rs.person_id
        AND mr.measurement_concept_id = rs.measurement_concept_id
    LEFT JOIN LabsFlag lf
        ON  mr.person_id              = lf.person_id
        AND mr.measurement_concept_id = lf.measurement_concept_id
    GROUP BY mr.person_id
),
procedures AS (
    SELECT patient_id, procedure_concept_id, procedure_date
    FROM procedure_occurrence
    WHERE procedure_concept_id IN (
        '2211329', '2211328', '2211327', '2211332', '2211330',
        '2211353','2211351','2211719','2212018','2212056','2212053'
    )
),

labs AS (
    SELECT DISTINCT
        patient_id,
        MAX(measurement_date) AS most_recent_measurement
    FROM measurement
    WHERE measurement_concept_id IN (
        '3003722','3050174','3043102','42868556','1469579',
        '1092155','1259491','3011498','3029139','3042151',
        '1761505','1617650','1616613','3042810','42868555','1617024'
    )
    GROUP BY patient_id
),

procedures_model AS (
    SELECT
        p.patient_id,

        -- CONCEPT: 2211329 computed tomography, head or brain; without contrast material, followed by contrast material(s) and further sections
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211329,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211329'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211329,

        -- CONCEPT: 2211328 computed tomography, head or brain; with contrast material(s)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211328,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211328'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211328,

        -- CONCEPT: 2211327 computed tomography, head or brain; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211327,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211327'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211327,

        -- CONCEPT: 2211332 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material, followed by contrast material(s) and further sections  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211332,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211332'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211332,

        -- CONCEPT: 2211330 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211330,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211330'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211330,

        -- CONCEPT: 2211353 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material, followed by contrast material(s) and further sequences 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211353,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211353'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211353,

        -- CONCEPT: 2211351 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material  
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211351,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211351'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211351,

        -- CONCEPT: 2211719 magnetic resonance spectroscopy 
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2211719,

        MAX(CASE
            WHEN p.procedure_concept_id = '2211719'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2211719,

        -- CONCEPT: 2212018 brain imaging, positron emission tomography (pet); metabolic evaluation   
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2212018,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212018'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212018,

        -- CONCEPT: 2212056 positron emission tomography (pet) with concurrently acquired computed tomography (ct) for attenuation correction and anatomical localization imaging; limited area (eg, chest, head/neck)    
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2212056,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212056'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212056,

        -- CONCEPT: 2212053 positron emission tomography (pet) imaging; limited area (eg, chest, head/neck)
        COUNT(DISTINCT CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
            THEN p.procedure_date
        END) AS procedure_count_180d_2212053,

        MAX(CASE
            WHEN p.procedure_concept_id = '2212053'
             AND p.procedure_date <= l.most_recent_measurement
             AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
            THEN 1 ELSE 0
        END) AS procedure_within_90d_2212053

    FROM procedures p
    JOIN labs l ON p.patient_id = l.patient_id
    GROUP BY p.patient_id
),


Updated_query AS (
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

    -- ── Drug exposure columns ────────────────────────────────────────────────

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
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%'     THEN dcc.exposed_91_180d END), 0)         AS risperidone_91_180d,

    -- ── Lab columns (NULL = patient had no result for that concept) ──────────

    la.lab_3003722_most_recent,  la.lab_3003722_previous,  la.lab_3003722_mean_90d,  la.lab_3003722_median_90d,  la.lab_3003722_abnormal_flag,
    la.lab_3050174_most_recent,  la.lab_3050174_previous,  la.lab_3050174_mean_90d,  la.lab_3050174_median_90d,  la.lab_3050174_abnormal_flag,
    la.lab_3043102_most_recent,  la.lab_3043102_previous,  la.lab_3043102_mean_90d,  la.lab_3043102_median_90d,  la.lab_3043102_abnormal_flag,
    la.lab_42868556_most_recent, la.lab_42868556_previous, la.lab_42868556_mean_90d, la.lab_42868556_median_90d, la.lab_42868556_abnormal_flag,
    la.lab_1469579_most_recent,  la.lab_1469579_previous,  la.lab_1469579_mean_90d,  la.lab_1469579_median_90d,  la.lab_1469579_abnormal_flag,
    la.lab_1092155_most_recent,  la.lab_1092155_previous,  la.lab_1092155_mean_90d,  la.lab_1092155_median_90d,  la.lab_1092155_abnormal_flag,
    la.lab_1259491_most_recent,  la.lab_1259491_previous,  la.lab_1259491_mean_90d,  la.lab_1259491_median_90d,  la.lab_1259491_abnormal_flag,
    la.lab_3011498_most_recent,  la.lab_3011498_previous,  la.lab_3011498_mean_90d,  la.lab_3011498_median_90d,  la.lab_3011498_abnormal_flag,
    la.lab_3029139_most_recent,  la.lab_3029139_previous,  la.lab_3029139_mean_90d,  la.lab_3029139_median_90d,  la.lab_3029139_abnormal_flag,
    la.lab_3042151_most_recent,  la.lab_3042151_previous,  la.lab_3042151_mean_90d,  la.lab_3042151_median_90d,  la.lab_3042151_abnormal_flag,
    la.lab_1761505_most_recent,  la.lab_1761505_previous,  la.lab_1761505_mean_90d,  la.lab_1761505_median_90d,  la.lab_1761505_abnormal_flag,
    la.lab_1617650_most_recent,  la.lab_1617650_previous,  la.lab_1617650_mean_90d,  la.lab_1617650_median_90d,  la.lab_1617650_abnormal_flag,
    la.lab_1616613_most_recent,  la.lab_1616613_previous,  la.lab_1616613_mean_90d,  la.lab_1616613_median_90d,  la.lab_1616613_abnormal_flag,
    la.lab_3042810_most_recent,  la.lab_3042810_previous,  la.lab_3042810_mean_90d,  la.lab_3042810_median_90d,  la.lab_3042810_abnormal_flag,
    la.lab_42868555_most_recent, la.lab_42868555_previous, la.lab_42868555_mean_90d, la.lab_42868555_median_90d, la.lab_42868555_abnormal_flag,
    la.lab_1617024_most_recent,  la.lab_1617024_previous,  la.lab_1617024_mean_90d,  la.lab_1617024_median_90d,  la.lab_1617024_abnormal_flag

FROM EligibleCohort ec
JOIN Demographics d
    ON ec.person_id = d.person_id
LEFT JOIN drug_cohort_collapsed dcc       -- LEFT so drug-naive patients are retained
    ON ec.person_id = dcc.person_id
LEFT JOIN drug_hierarchy dh
    ON dcc.drug_concept_id = dh.drug_concept_id
INNER JOIN CogScoreAgg csa
    ON ec.person_id = csa.person_id
LEFT JOIN LabsAgg la
    ON ec.person_id = la.person_id
WHERE (
    la.lab_3003722_most_recent  IS NOT NULL OR
    la.lab_3050174_most_recent  IS NOT NULL OR
    la.lab_3043102_most_recent  IS NOT NULL OR
    la.lab_42868556_most_recent IS NOT NULL OR
    la.lab_1469579_most_recent  IS NOT NULL OR
    la.lab_1092155_most_recent  IS NOT NULL OR
    la.lab_1259491_most_recent  IS NOT NULL OR
    la.lab_3011498_most_recent  IS NOT NULL OR
    la.lab_3029139_most_recent  IS NOT NULL OR
    la.lab_3042151_most_recent  IS NOT NULL OR
    la.lab_1761505_most_recent  IS NOT NULL OR
    la.lab_1617650_most_recent  IS NOT NULL OR
    la.lab_1616613_most_recent  IS NOT NULL OR
    la.lab_3042810_most_recent  IS NOT NULL OR
    la.lab_42868555_most_recent IS NOT NULL OR
    la.lab_1617024_most_recent  IS NOT NULL
)
GROUP BY
    ec.person_id,
    ec.index_date,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity,
    csa.first_score,
    csa.last_score,
    csa.avg_followup_score,
    -- Lab columns must be in GROUP BY because they come from a pre-aggregated CTE,
    -- not from the drug pivot aggregation above
    la.lab_3003722_most_recent,  la.lab_3003722_previous,  la.lab_3003722_mean_90d,  la.lab_3003722_median_90d,  la.lab_3003722_abnormal_flag,
    la.lab_3050174_most_recent,  la.lab_3050174_previous,  la.lab_3050174_mean_90d,  la.lab_3050174_median_90d,  la.lab_3050174_abnormal_flag,
    la.lab_3043102_most_recent,  la.lab_3043102_previous,  la.lab_3043102_mean_90d,  la.lab_3043102_median_90d,  la.lab_3043102_abnormal_flag,
    la.lab_42868556_most_recent, la.lab_42868556_previous, la.lab_42868556_mean_90d, la.lab_42868556_median_90d, la.lab_42868556_abnormal_flag,
    la.lab_1469579_most_recent,  la.lab_1469579_previous,  la.lab_1469579_mean_90d,  la.lab_1469579_median_90d,  la.lab_1469579_abnormal_flag,
    la.lab_1092155_most_recent,  la.lab_1092155_previous,  la.lab_1092155_mean_90d,  la.lab_1092155_median_90d,  la.lab_1092155_abnormal_flag,
    la.lab_1259491_most_recent,  la.lab_1259491_previous,  la.lab_1259491_mean_90d,  la.lab_1259491_median_90d,  la.lab_1259491_abnormal_flag,
    la.lab_3011498_most_recent,  la.lab_3011498_previous,  la.lab_3011498_mean_90d,  la.lab_3011498_median_90d,  la.lab_3011498_abnormal_flag,
    la.lab_3029139_most_recent,  la.lab_3029139_previous,  la.lab_3029139_mean_90d,  la.lab_3029139_median_90d,  la.lab_3029139_abnormal_flag,
    la.lab_3042151_most_recent,  la.lab_3042151_previous,  la.lab_3042151_mean_90d,  la.lab_3042151_median_90d,  la.lab_3042151_abnormal_flag,
    la.lab_1761505_most_recent,  la.lab_1761505_previous,  la.lab_1761505_mean_90d,  la.lab_1761505_median_90d,  la.lab_1761505_abnormal_flag,
    la.lab_1617650_most_recent,  la.lab_1617650_previous,  la.lab_1617650_mean_90d,  la.lab_1617650_median_90d,  la.lab_1617650_abnormal_flag,
    la.lab_1616613_most_recent,  la.lab_1616613_previous,  la.lab_1616613_mean_90d,  la.lab_1616613_median_90d,  la.lab_1616613_abnormal_flag,
    la.lab_3042810_most_recent,  la.lab_3042810_previous,  la.lab_3042810_mean_90d,  la.lab_3042810_median_90d,  la.lab_3042810_abnormal_flag,
    la.lab_42868555_most_recent, la.lab_42868555_previous, la.lab_42868555_mean_90d, la.lab_42868555_median_90d, la.lab_42868555_abnormal_flag,
    la.lab_1617024_most_recent,  la.lab_1617024_previous,  la.lab_1617024_mean_90d,  la.lab_1617024_median_90d,  la.lab_1617024_abnormal_flag

    )
SELECT
    uq.person_id,
    uq.first_score,
    uq.last_score,
    uq.score_delta,
    uq.avg_followup_score,
    uq.age_at_index,
    uq.sex,
    uq.race,
    uq.ethnicity,
    uq.index_date,

    -- Drugs
    uq.haloperidol_days, uq.haloperidol_0_30d, uq.haloperidol_31_90d, uq.haloperidol_91_180d,
    uq.lecanemab_days, uq.lecanemab_0_30d, uq.lecanemab_31_90d, uq.lecanemab_91_180d,
    uq.donanemab_days, uq.donanemab_0_30d, uq.donanemab_31_90d, uq.donanemab_91_180d,
    uq.brexpiprazole_days, uq.brexpiprazole_0_30d, uq.brexpiprazole_31_90d, uq.brexpiprazole_91_180d,
    uq.memantine_days, uq.memantine_0_30d, uq.memantine_31_90d, uq.memantine_91_180d,
    uq.donepezil_days, uq.donepezil_0_30d, uq.donepezil_31_90d, uq.donepezil_91_180d,
    uq.rivastigmine_days, uq.rivastigmine_0_30d, uq.rivastigmine_31_90d, uq.rivastigmine_91_180d,
    uq.galantamine_days, uq.galantamine_0_30d, uq.galantamine_31_90d, uq.galantamine_91_180d,
    uq.benzgalantamine_days, uq.benzgalantamine_0_30d, uq.benzgalantamine_31_90d, uq.benzgalantamine_91_180d,
    uq.suvorexant_days, uq.suvorexant_0_30d, uq.suvorexant_31_90d, uq.suvorexant_91_180d,
    uq.risperidone_days, uq.risperidone_0_30d, uq.risperidone_31_90d, uq.risperidone_91_180d,

    -- Rename format for specific target labs 
    uq.lab_42868556_most_recent AS most_recent_score_amyloid_beta_40,
    uq.lab_42868556_previous AS previous_score_amyloid_beta_40,
    FORMAT_NUMBER(uq.lab_42868556_mean_90d, 5) AS rolling_mean_90d_amyloid_beta_40,
    FORMAT_NUMBER(uq.lab_42868556_median_90d, 5) AS rolling_median_90d_amyloid_beta_40,
    uq.lab_42868556_abnormal_flag AS abnormal_flag_amyloid_beta_40,

    uq.lab_3003722_most_recent AS most_recent_score_amyloid_associated_protein,
    uq.lab_3003722_previous AS previous_score_amyloid_associated_protein,
    FORMAT_NUMBER(uq.lab_3003722_mean_90d, 5) AS rolling_mean_90d_amyloid_associated_protein,
    FORMAT_NUMBER(uq.lab_3003722_median_90d, 5) AS rolling_median_90d_amyloid_associated_protein,
    uq.lab_3003722_abnormal_flag AS abnormal_flag_amyloid_associated_protein,

    uq.lab_3050174_most_recent AS most_recent_score_ykl40,
    uq.lab_3050174_previous AS previous_score_ykl40,
    FORMAT_NUMBER(uq.lab_3050174_mean_90d, 5) AS rolling_mean_90d_ykl40,
    FORMAT_NUMBER(uq.lab_3050174_median_90d, 5) AS rolling_median_90d_ykl40,
    uq.lab_3050174_abnormal_flag AS abnormal_flag_ykl40,

    uq.lab_3043102_most_recent AS most_recent_score_amyloid_beta_42,
    uq.lab_3043102_previous AS previous_score_amyloid_beta_42,
    FORMAT_NUMBER(uq.lab_3043102_mean_90d, 5) AS rolling_mean_90d_amyloid_beta_42,
    FORMAT_NUMBER(uq.lab_3043102_median_90d, 5) AS rolling_median_90d_amyloid_beta_42,
    uq.lab_3043102_abnormal_flag AS abnormal_flag_amyloid_beta_42,

    uq.lab_1469579_most_recent AS most_recent_score_amyloid_beta_42_40_ratio,
    uq.lab_1469579_previous AS previous_score_amyloid_beta_42_40_ratio,
    FORMAT_NUMBER(uq.lab_1469579_mean_90d, 5) AS rolling_mean_90d_amyloid_beta_42_40_ratio,
    FORMAT_NUMBER(uq.lab_1469579_median_90d, 5) AS rolling_median_90d_amyloid_beta_42_40_ratio,
    uq.lab_1469579_abnormal_flag AS abnormal_flag_amyloid_beta_42_40_ratio,

    uq.lab_1092155_most_recent AS most_recent_score_tau_phosphorylated_217,
    uq.lab_1092155_previous AS previous_score_tau_phosphorylated_217,
    FORMAT_NUMBER(uq.lab_1092155_mean_90d, 5) AS rolling_mean_90d_tau_phosphorylated_217,
    FORMAT_NUMBER(uq.lab_1092155_median_90d, 5) AS rolling_median_90d_tau_phosphorylated_217,
    uq.lab_1092155_abnormal_flag AS abnormal_flag_tau_phosphorylated_217,

    -- Include the remaining raw lab columns if needed
    uq.lab_1259491_most_recent, uq.lab_1259491_previous, uq.lab_1259491_mean_90d, uq.lab_1259491_median_90d, uq.lab_1259491_abnormal_flag,
    uq.lab_3011498_most_recent, uq.lab_3011498_previous, uq.lab_3011498_mean_90d, uq.lab_3011498_median_90d, uq.lab_3011498_abnormal_flag,
    uq.lab_3029139_most_recent, uq.lab_3029139_previous, uq.lab_3029139_mean_90d, uq.lab_3029139_median_90d, uq.lab_3029139_abnormal_flag,
    uq.lab_3042151_most_recent, uq.lab_3042151_previous, uq.lab_3042151_mean_90d, uq.lab_3042151_median_90d, uq.lab_3042151_abnormal_flag,
    uq.lab_1761505_most_recent, uq.lab_1761505_previous, uq.lab_1761505_mean_90d, uq.lab_1761505_median_90d, uq.lab_1761505_abnormal_flag,
    uq.lab_1617650_most_recent, uq.lab_1617650_previous, uq.lab_1617650_mean_90d, uq.lab_1617650_median_90d, uq.lab_1617650_abnormal_flag,
    uq.lab_1616613_most_recent, uq.lab_1616613_previous, uq.lab_1616613_mean_90d, uq.lab_1616613_median_90d, uq.lab_1616613_abnormal_flag,
    uq.lab_3042810_most_recent, uq.lab_3042810_previous, uq.lab_3042810_mean_90d, uq.lab_3042810_median_90d, uq.lab_3042810_abnormal_flag,
    uq.lab_42868555_most_recent, uq.lab_42868555_previous, uq.lab_42868555_mean_90d, uq.lab_42868555_median_90d, uq.lab_42868555_abnormal_flag,
    uq.lab_1617024_most_recent, uq.lab_1617024_previous, uq.lab_1617024_mean_90d, uq.lab_1617024_median_90d, uq.lab_1617024_abnormal_flag,

    -- Procedures
    pm.*
FROM Updated_query uq
LEFT JOIN procedures_model pm
    ON uq.person_id = pm.patient_id
WHERE 
    -- Keep the row if ANY of these 6 explicit labs or a procedure exist
    uq.lab_42868556_most_recent IS NOT NULL OR
    uq.lab_3003722_most_recent IS NOT NULL OR
    uq.lab_3050174_most_recent IS NOT NULL OR
    uq.lab_3043102_most_recent IS NOT NULL OR
    uq.lab_1469579_most_recent IS NOT NULL OR
    uq.lab_1092155_most_recent IS NOT NULL OR
    pm.patient_id IS NOT NULL

ORDER BY uq.person_id;

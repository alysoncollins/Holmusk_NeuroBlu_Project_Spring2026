WITH labs_cohort AS (
    SELECT
        person_id,
        measurement_id,
        measurement_concept_id,
        measurement_datetime,
        value_as_number
    FROM measurement
    WHERE measurement_concept_id IN (
        '3003722','3050174','3043102','42868556','1469579',
        '1092155','1259491','3011498','3029139','3042151',
        '1761505','1617650','1616613','3042810','42868555','1617024'
    )
    AND value_as_number IS NOT NULL
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

ranked AS (
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
    FROM labs_cohort
),

most_recent AS (
    SELECT
        person_id,
        measurement_concept_id,
        value_as_number AS most_recent_score,
        previous_score,
        previous_score_datetime,
        measurement_datetime
    FROM ranked
    WHERE rn = 1
),

rolling_stats AS (
    SELECT
        r.person_id,
        r.measurement_concept_id,
        AVG(r.value_as_number)                                          AS rolling_mean_90d,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.value_as_number) AS rolling_median_90d,
        COUNT(*)                                                        AS measurement_count_90d
    FROM labs_cohort r
    INNER JOIN most_recent m
        ON r.person_id = m.person_id
        AND r.measurement_concept_id = m.measurement_concept_id
    WHERE r.measurement_datetime BETWEEN m.measurement_datetime - INTERVAL 90 DAYS AND m.measurement_datetime
    GROUP BY r.person_id, r.measurement_concept_id
),

flag AS (
    SELECT
        r.person_id,
        r.measurement_concept_id,
        CASE
            WHEN m.range_low IS NULL AND m.range_high IS NULL THEN NULL
            WHEN r.value_as_number < m.range_low  THEN 1
            WHEN r.value_as_number > m.range_high THEN 1
            ELSE 0
        END AS abnormal_flag
    FROM ranked r
    INNER JOIN measurement m
        ON r.person_id = m.person_id
        AND r.measurement_concept_id = m.measurement_concept_id
        AND r.measurement_datetime = m.measurement_datetime
    WHERE r.rn = 1
)

SELECT
    cd.person_id,
    --cd.index_date,
    --cd.diagnosis_type,


    -- CONCEPT: 42868556 | amyloid_beta_40_peptide
    mr_42868556.most_recent_score                          AS most_recent_score_amyloid_beta_40,
    mr_42868556.previous_score                             AS previous_score_amyloid_beta_40,
    FORMAT_NUMBER(rs_42868556.rolling_mean_90d,   5)       AS rolling_mean_90d_amyloid_beta_40,
    FORMAT_NUMBER(rs_42868556.rolling_median_90d, 5)       AS rolling_median_90d_amyloid_beta_40,
    f_42868556.abnormal_flag                               AS abnormal_flag_amyloid_beta_40,

    -- CONCEPT: 3003722 | amyloid_associated_protein
    mr_3003722.most_recent_score                           AS most_recent_score_amyloid_associated_protein,
    mr_3003722.previous_score                              AS previous_score_amyloid_associated_protein,
    FORMAT_NUMBER(rs_3003722.rolling_mean_90d,   5)        AS rolling_mean_90d_amyloid_associated_protein,
    FORMAT_NUMBER(rs_3003722.rolling_median_90d, 5)        AS rolling_median_90d_amyloid_associated_protein,
    f_3003722.abnormal_flag                                AS abnormal_flag_amyloid_associated_protein,

    -- CONCEPT: 3050174 | ykl40
    mr_3050174.most_recent_score                           AS most_recent_score_ykl40,
    mr_3050174.previous_score                              AS previous_score_ykl40,
    FORMAT_NUMBER(rs_3050174.rolling_mean_90d,   5)        AS rolling_mean_90d_ykl40,
    FORMAT_NUMBER(rs_3050174.rolling_median_90d, 5)        AS rolling_median_90d_ykl40,
    f_3050174.abnormal_flag                                AS abnormal_flag_ykl40,


    -- CONCEPT: 3043102 | amyloid_beta_42_peptide
    mr_3043102.most_recent_score                           AS most_recent_score_amyloid_beta_42,
    mr_3043102.previous_score                              AS previous_score_amyloid_beta_42,
    FORMAT_NUMBER(rs_3043102.rolling_mean_90d,   5)        AS rolling_mean_90d_amyloid_beta_42,
    FORMAT_NUMBER(rs_3043102.rolling_median_90d, 5)        AS rolling_median_90d_amyloid_beta_42,
    f_3043102.abnormal_flag                                AS abnormal_flag_amyloid_beta_42,

    -- CONCEPT: 1469579 | amyloid_beta_42_40_ratio
    mr_1469579.most_recent_score                           AS most_recent_score_amyloid_beta_42_40_ratio,
    mr_1469579.previous_score                              AS previous_score_amyloid_beta_42_40_ratio,
    FORMAT_NUMBER(rs_1469579.rolling_mean_90d,   5)        AS rolling_mean_90d_amyloid_beta_42_40_ratio,
    FORMAT_NUMBER(rs_1469579.rolling_median_90d, 5)        AS rolling_median_90d_amyloid_beta_42_40_ratio,
    f_1469579.abnormal_flag                                AS abnormal_flag_amyloid_beta_42_40_ratio,

    -- CONCEPT: 1092155 | tau_phosphorylated_217
    mr_1092155.most_recent_score                           AS most_recent_score_tau_phosphorylated_217,
    mr_1092155.previous_score                              AS previous_score_tau_phosphorylated_217,
    FORMAT_NUMBER(rs_1092155.rolling_mean_90d,   5)        AS rolling_mean_90d_tau_phosphorylated_217,
    FORMAT_NUMBER(rs_1092155.rolling_median_90d, 5)        AS rolling_median_90d_tau_phosphorylated_217,
    f_1092155.abnormal_flag                                AS abnormal_flag_tau_phosphorylated_217

    
FROM CohortDiagnosis cd

-- JOINS: 42868556
LEFT JOIN most_recent mr_42868556
    ON cd.person_id = mr_42868556.person_id
    AND mr_42868556.measurement_concept_id = '42868556'
LEFT JOIN rolling_stats rs_42868556
    ON cd.person_id = rs_42868556.person_id
    AND rs_42868556.measurement_concept_id = '42868556'
LEFT JOIN flag f_42868556
    ON cd.person_id = f_42868556.person_id
    AND f_42868556.measurement_concept_id = '42868556'

-- JOINS: 3003722
LEFT JOIN most_recent mr_3003722
    ON cd.person_id = mr_3003722.person_id
    AND mr_3003722.measurement_concept_id = '3003722'
LEFT JOIN rolling_stats rs_3003722
    ON cd.person_id = rs_3003722.person_id
    AND rs_3003722.measurement_concept_id = '3003722'
LEFT JOIN flag f_3003722
    ON cd.person_id = f_3003722.person_id
    AND f_3003722.measurement_concept_id = '3003722'

-- JOINS: 3050174
LEFT JOIN most_recent mr_3050174
    ON cd.person_id = mr_3050174.person_id                 
    AND mr_3050174.measurement_concept_id = '3050174'      
LEFT JOIN rolling_stats rs_3050174
    ON cd.person_id = rs_3050174.person_id
    AND rs_3050174.measurement_concept_id = '3050174'
LEFT JOIN flag f_3050174
    ON cd.person_id = f_3050174.person_id
    AND f_3050174.measurement_concept_id = '3050174'      

-- JOINS: 3043102
LEFT JOIN most_recent mr_3043102
    ON cd.person_id = mr_3043102.person_id
    AND mr_3043102.measurement_concept_id = '3043102'
LEFT JOIN rolling_stats rs_3043102
    ON cd.person_id = rs_3043102.person_id
    AND rs_3043102.measurement_concept_id = '3043102'
LEFT JOIN flag f_3043102
    ON cd.person_id = f_3043102.person_id
    AND f_3043102.measurement_concept_id = '3043102'

-- JOINS: 1469579
LEFT JOIN most_recent mr_1469579                           
    ON cd.person_id = mr_1469579.person_id
    AND mr_1469579.measurement_concept_id = '1469579'
LEFT JOIN rolling_stats rs_1469579
    ON cd.person_id = rs_1469579.person_id
    AND rs_1469579.measurement_concept_id = '1469579'
LEFT JOIN flag f_1469579
    ON cd.person_id = f_1469579.person_id
    AND f_1469579.measurement_concept_id = '1469579'

-- JOINS: 1092155
LEFT JOIN most_recent mr_1092155                           
    ON cd.person_id = mr_1092155.person_id
    AND mr_1092155.measurement_concept_id = '1092155'
LEFT JOIN rolling_stats rs_1092155
    ON cd.person_id = rs_1092155.person_id
    AND rs_1092155.measurement_concept_id = '1092155'
LEFT JOIN flag f_1092155
    ON cd.person_id = f_1092155.person_id
    AND f_1092155.measurement_concept_id = '1092155'


--can be removed for full implementation, just here to ensure data was calculated right and easier to find
WHERE NOT (
    mr_42868556.most_recent_score IS NULL
    AND mr_3003722.most_recent_score IS NULL
    AND mr_3050174.most_recent_score IS NULL
    AND mr_3043102.most_recent_score IS NULL
    AND mr_1469579.most_recent_score IS NULL
    AND mr_1092155.most_recent_score IS NULL
)

ORDER BY cd.person_id
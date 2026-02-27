WITH labs_cohort AS ( 
    /*gather data from measurements that meet the requirements 
    of patient_count > 50. This list is precalculated to avoid 
    unneccessary complexity in the query*/  
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
    
ranked AS (
    /*gathers immediately previous data from patients */
    SELECT 
        person_id,
        measurement_concept_id,
        measurement_datetime,
        value_as_number,
        ROW_NUMBER() OVER ( --numbers each row per person to more easily call upon thier specific order later
            PARTITION BY person_id
            ORDER BY measurement_datetime DESC, measurement_id DESC
        ) AS rn,
        LAG(value_as_number) OVER ( --gathers previous value before most recent
            PARTITION BY person_id
            ORDER BY measurement_datetime ASC, measurement_id ASC
        ) AS previous_score,
        LAG(measurement_datetime) OVER ( --gathers previous datetime
            PARTITION BY person_id
            ORDER BY measurement_datetime ASC, measurement_id ASC
        ) AS previous_score_datetime,
        LAG(measurement_concept_id) OVER ( --gathers previous concept_id
            PARTITION BY person_id
            ORDER BY measurement_datetime ASC, measurement_id ASC
        ) AS previous_score_concept
        
    FROM labs_cohort
),

most_recent AS (
    /* gathers specifically the most recent data as was sorted by ranked */
    SELECT
        person_id,
        measurement_concept_id,
        value_as_number AS most_recent_score,
        previous_score,
        previous_score_datetime,
        previous_score_concept,
        measurement_datetime
    FROM ranked
    WHERE rn = 1
),
rolling_stats AS (
    /* Calculates rolling mean and median based on the the last 
    90 days from a patients most recent measurement.
    Current calculations not taking into account any standardization 
    between scores of different concepts. Scores still must be standardized.*/
    SELECT
        r.person_id,
        AVG(r.value_as_number) AS rolling_mean_90d,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.value_as_number) AS rolling_median_90d,
        COUNT(*) AS measurement_count_90d
    FROM labs_cohort r
    INNER JOIN most_recent m ON r.person_id = m.person_id
    WHERE r.measurement_datetime BETWEEN m.measurement_datetime - INTERVAL 90 DAYS AND m.measurement_datetime
    GROUP BY r.person_id
)

SELECT
    m.person_id,
    m.measurement_concept_id,
    m.most_recent_score,
    m.previous_score_concept,
    m.previous_score,
    FORMAT_NUMBER(s.rolling_mean_90d,5) AS rolling_mean_90d,
    FORMAT_NUMBER(s.rolling_median_90d,5) AS rolling_median_90d
    
FROM most_recent m
LEFT JOIN rolling_stats s ON m.person_id = s.person_id
ORDER BY m.person_id
LIMIT 1000;  --limited to save on query time
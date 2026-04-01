#This script contains Master_Cohort() which returns the Cohort for the project using relative cutoff as the standardization
def Master_Cohort():
    return """
-- Identify target drug concept IDs 
-- Note: This is the "List of Drugs to be used" section, and brand_name is the (R) in each drug of the section
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

-- First diagnosis date of MCI OR Dementia OR Alzheimer's disease
CohortDiagnosis AS (
    SELECT
        co.person_id,
        MIN(co.condition_start_date) AS index_date, -- MIN is used to define the index date as the first diagnosis of MCI, Dementia, or Alzheimer's disease
        MAX(c.concept_name) AS diagnosis_type -- MAX is used to retain a readable diagnosis label
    FROM condition_occurrence co
    JOIN concept c
    ON co.condition_concept_id = c.concept_id
    WHERE c.concept_name LIKE '%mild cognitive% impairment%' -- OR is used since it can be any of the three
       OR c.concept_name LIKE '%dementia%'
       OR c.concept_name LIKE '%alzheimer%'
    GROUP BY co.person_id
),

-- At least 1 drug exposure for the list of drugs
DrugUsers AS (
    SELECT DISTINCT
        de.person_id
    FROM drug_exposure de
    JOIN DrugsUsed du
    ON de.drug_concept_id = du.drug_concept_id
    JOIN CohortDiagnosis cd
    ON de.person_id = cd.person_id
    AND de.drug_exposure_start_date >= cd.index_date -- Ensure the drug exposure occurs ON or AFTER the index date
),

-- Cutoff parameters per scale
TestCutoffs AS (
    SELECT 'minicog' AS scale, 3.0  AS cutoff, 5.0  AS upper_bound
    UNION ALL SELECT 'mmse',   24.0,            30.0
    UNION ALL SELECT 'moca',   26.0,            30.0
),

-- Cognitive scores with standardized cutoff score
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
    JOIN measurement_lookup ml
        ON m.custom2_str = ml.custom2_str
    JOIN TestCutoffs tc
        ON ml.scale = tc.scale
    JOIN CohortDiagnosis cd
        ON m.person_id = cd.person_id
    WHERE ml.scale IN ('minicog', 'moca', 'mmse')
        AND m.value_as_number IS NOT NULL
        AND m.measurement_date >= cd.index_date
),

-- First cognitive score per patient (earliest date)
FirstScore AS (
    SELECT
        cs.person_id,
        cs.cutoff_score AS first_score
    FROM CognitiveScores cs
    JOIN (
        SELECT person_id, MIN(measurement_date) AS min_date
        FROM CognitiveScores
        GROUP BY person_id
    ) first_dates
    ON cs.person_id = first_dates.person_id
    AND cs.measurement_date = first_dates.min_date
),
-- Last cognitive score per patient (latest date)
LastScore AS (
    SELECT
        cs.person_id,
        cs.cutoff_score AS last_score
    FROM CognitiveScores cs
    JOIN (
        SELECT person_id, MAX(measurement_date) AS max_date
        FROM CognitiveScores
        GROUP BY person_id
    ) last_dates
    ON cs.person_id = last_dates.person_id
    AND cs.measurement_date = last_dates.max_date
),

-- Patient demographics at index date
Demographics AS (
    SELECT
        p.person_id,
        (YEAR(cd.index_date) - p.year_of_birth) AS age_at_index,
        g.concept_name AS sex,
        r.concept_name AS race,
        e.concept_name AS ethnicity
    FROM person p
    JOIN CohortDiagnosis cd
        ON p.person_id = cd.person_id
    LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
    LEFT JOIN concept r ON p.race_concept_id = r.concept_id
    LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
    WHERE LOWER(g.concept_name) NOT LIKE '%no matching concept%'
        AND LOWER(r.concept_name) NOT LIKE '%no matching concept%'
        AND LOWER(e.concept_name) NOT LIKE '%no matching concept%'
)

SELECT
    cs.person_id,
    -- Demographics
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity,
    -- Average, First, and last scores
    AVG(cs.cutoff_score)   AS avg_followup_score,
    fs.first_score,
    ls.last_score,
    -- Score change over time
    (ls.last_score - fs.first_score) AS score_delta
    
FROM CognitiveScores cs
    --Joined Tables
JOIN CohortDiagnosis cd  
    ON cs.person_id = cd.person_id
JOIN DrugUsers du        
    ON cs.person_id = du.person_id
JOIN observation_period op 
    ON cs.person_id = op.person_id
JOIN FirstScore fs       
    ON cs.person_id = fs.person_id   -- join first score
JOIN LastScore ls        
    ON cs.person_id = ls.person_id   -- join last score
    JOIN Demographics d
    ON cs.person_id = d.person_id
GROUP BY
    cs.person_id,
    op.observation_period_end_date,
    cd.index_date,
    fs.first_score,
    ls.last_score,
    d.age_at_index,
    d.sex,
    d.race,
    d.ethnicity
HAVING DATEDIFF('day', cd.index_date, op.observation_period_end_date) >= 180 -- Enforces at least 6 months (180) of observation after index date
"""
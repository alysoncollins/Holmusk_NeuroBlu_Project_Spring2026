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

drug_cohort AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        cd.index_date,
        (DATEDIFF('day', de.drug_exposure_start_date, de.drug_exposure_end_date)+1) AS cumulative_days_exposed,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(cd.index_date, 30)
            AND  de.drug_exposure_end_date   >= cd.index_date
            THEN 1 ELSE 0
        END AS exposed_0_30d,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(cd.index_date, 90)
            AND  de.drug_exposure_end_date   >= DATE_ADD(cd.index_date, 31)
            THEN 1 ELSE 0
        END AS exposed_31_90d,
        CASE
            WHEN de.drug_exposure_start_date <= DATE_ADD(cd.index_date, 180)
            AND  de.drug_exposure_end_date   >= DATE_ADD(cd.index_date, 91)
            THEN 1 ELSE 0
        END AS exposed_91_180d
    FROM drug_exposure de
    INNER JOIN CohortDiagnosis cd    
        ON de.person_id = cd.person_id
    WHERE de.drug_exposure_start_date <= DATE_ADD(cd.index_date, 180)
        AND de.drug_exposure_start_date >= cd.index_date
),

drug_hierarchy AS ( 
    /*pulls drug information related only to the drugs given in the outline. 
    Used to sort the data to specifically patients who have taken the drugs we are interested in*/
        SELECT DISTINCT
        dl.drug_concept_id,
        cdim.ingredient_concept_name AS ingredient_level,
        dl.drug_concept_name AS component_level,
        dpl.brand_name AS brand_level
    FROM drug_lookup dl
    INNER JOIN clinical_drug_ingredient_mapping cdim 
        ON dl.drug_concept_id = cdim.drug_concept_id
    INNER JOIN drug_product_lookup dpl 
        ON dl.drug_concept_id = dpl.drug_concept_id
    WHERE cdim.ingredient_concept_name LIKE '%haloperidol%'
        OR ingredient_concept_name LIKE '%lecanemab%'
        OR ingredient_concept_name LIKE '%donanemab%'
        OR ingredient_concept_name LIKE '%brexpiprazole%'
        OR ingredient_concept_name LIKE '%memantine%'
        OR ingredient_concept_name LIKE '%donepezil%'
        OR ingredient_concept_name LIKE '%rivastigmine%'
        OR ingredient_concept_name LIKE '%galantamine%'
        OR ingredient_concept_name LIKE '%benzgalantamine%'
        OR ingredient_concept_name LIKE '%memantine%'
        OR ingredient_concept_name LIKE '%suvorexant%'
        OR ingredient_concept_name LIKE '%risperidone%'
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

--drug cohort pre aggregated such that some elements are summed properly
drug_cohort_collapsed AS (
    SELECT
        dc.person_id,
        dc.drug_concept_id,
        dh.ingredient_level,     
        dc.index_date,
        SUM(dc.cumulative_days_exposed) AS cumulative_days_exposed,  
        MAX(dc.exposed_0_30d)  AS exposed_0_30d,
        MAX(dc.exposed_31_90d) AS exposed_31_90d,
        MAX(dc.exposed_91_180d) AS exposed_91_180d
    FROM drug_cohort dc
    INNER JOIN drug_hierarchy dh
        ON dc.drug_concept_id = dh.drug_concept_id
    GROUP BY
        dc.person_id,
        dc.drug_concept_id,
        dh.ingredient_level,
        dc.index_date
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
    p.person_id,
    fs.first_score,
    ls.last_score,
    (ls.last_score - fs.first_score) AS score_delta,
    avg_cs.avg_followup_score,
    (YEAR(cd.index_date) - p.year_of_birth) AS age_at_index,
    g.concept_name AS sex,
    r.concept_name AS race,
    e.concept_name AS ethnicity,
    cd.index_date,

    -- Haloperidol
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.cumulative_days_exposed END), 0) AS haloperidol_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_0_30d END), 0)          AS haloperidol_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_31_90d END), 0)         AS haloperidol_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%haloperidol%' THEN dcc.exposed_91_180d END), 0)        AS haloperidol_91_180d,

    -- Lecanemab
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.cumulative_days_exposed END), 0)  AS lecanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_0_30d END), 0)            AS lecanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_31_90d END), 0)           AS lecanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%lecanemab%' THEN dcc.exposed_91_180d END), 0)          AS lecanemab_91_180d,

    -- Donanemab
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.cumulative_days_exposed END), 0)  AS donanemab_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_0_30d END), 0)            AS donanemab_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_31_90d END), 0)           AS donanemab_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donanemab%' THEN dcc.exposed_91_180d END), 0)          AS donanemab_91_180d,

    -- Brexpiprazole
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.cumulative_days_exposed END), 0) AS brexpiprazole_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_0_30d END), 0)           AS brexpiprazole_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_31_90d END), 0)          AS brexpiprazole_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%brexpiprazole%' THEN dcc.exposed_91_180d END), 0)         AS brexpiprazole_91_180d,

    -- Memantine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.cumulative_days_exposed END), 0)  AS memantine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_0_30d END), 0)            AS memantine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_31_90d END), 0)           AS memantine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%memantine%' THEN dcc.exposed_91_180d END), 0)          AS memantine_91_180d,

    -- Donepezil
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.cumulative_days_exposed END), 0)  AS donepezil_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_0_30d END), 0)            AS donepezil_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_31_90d END), 0)           AS donepezil_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%donepezil%' THEN dcc.exposed_91_180d END), 0)          AS donepezil_91_180d,

    -- Rivastigmine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.cumulative_days_exposed END), 0) AS rivastigmine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_0_30d END), 0)           AS rivastigmine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_31_90d END), 0)          AS rivastigmine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%rivastigmine%' THEN dcc.exposed_91_180d END), 0)         AS rivastigmine_91_180d,

    -- Galantamine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.cumulative_days_exposed END), 0) AS galantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_0_30d END), 0)           AS galantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_31_90d END), 0)          AS galantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%galantamine%' THEN dcc.exposed_91_180d END), 0)         AS galantamine_91_180d,

    -- Benzgalantamine
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.cumulative_days_exposed END), 0) AS benzgalantamine_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_0_30d END), 0)           AS benzgalantamine_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_31_90d END), 0)          AS benzgalantamine_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%benzgalantamine%' THEN dcc.exposed_91_180d END), 0)         AS benzgalantamine_91_180d,

    -- Suvorexant
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.cumulative_days_exposed END), 0)  AS suvorexant_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_0_30d END), 0)            AS suvorexant_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_31_90d END), 0)           AS suvorexant_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%suvorexant%' THEN dcc.exposed_91_180d END), 0)          AS suvorexant_91_180d,

    -- Risperidone
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.cumulative_days_exposed END), 0) AS risperidone_days,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_0_30d END), 0)           AS risperidone_0_30d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_31_90d END), 0)          AS risperidone_31_90d,
    COALESCE(MAX(CASE WHEN dh.ingredient_level LIKE '%risperidone%' THEN dcc.exposed_91_180d END), 0)         AS risperidone_91_180d

FROM person p
INNER JOIN CohortDiagnosis cd       
    ON p.person_id = cd.person_id
INNER JOIN drug_cohort_collapsed dcc 
    ON p.person_id = dcc.person_id
INNER JOIN drug_hierarchy dh        
    ON dcc.drug_concept_id = dh.drug_concept_id
LEFT JOIN concept g 
    ON p.gender_concept_id = g.concept_id
LEFT JOIN concept r 
    ON p.race_concept_id = r.concept_id
LEFT JOIN concept e 
    ON p.ethnicity_concept_id = e.concept_id
LEFT JOIN FirstScore fs
    ON p.person_id = fs.person_id
LEFT JOIN LastScore ls
    ON p.person_id = ls.person_id
LEFT JOIN (
    SELECT person_id, AVG(cutoff_score) AS avg_followup_score
    FROM CognitiveScores
    GROUP BY person_id
) avg_cs
    ON p.person_id = avg_cs.person_id
WHERE
    LOWER(g.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(r.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(e.concept_name) NOT LIKE '%no matching concept%'
GROUP BY
    p.person_id,
    age_at_index,
    g.concept_name,
    r.concept_name,
    e.concept_name,
    cd.index_date,
    fs.first_score,
    ls.last_score,
    avg_cs.avg_followup_score
ORDER BY p.person_id
"""
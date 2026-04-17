-- 4. Cohort Definition
 
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
 
-- First diagnosis date of MCI OR Dementia OR Alzheimer's disease
CohortDiagnosis AS (
    SELECT
        co.person_id,
        MIN(co.condition_start_date) AS index_date,
        -- MIN is used to define the index date as the first diagnosis of MCI, Dementia, or Alzheimer's disease
        MAX(d.icd_name) AS diagnosis_type -- MAX is used to retain a readable diagnosis label
    FROM condition_occurrence co
    JOIN diagnosis_lookup d
    ON co.condition_concept_id = d.icd_concept_id
    WHERE disorder_group = 'dementia'
    OR array_contains(keywords, 'mci')
    OR array_contains(keywords, 'ad')
    
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
 
-- At least one cognitive score (Mini-Cog, MoCA, or MMSE) after index date
CognitiveScores AS (
    SELECT
        m.person_id,
        m.measurement_date,
        m.value_as_number
    FROM measurement m
    JOIN measurement_lookup ml
    ON m.measurement_concept_id = ml.measurement_concept_id
    JOIN CohortDiagnosis cd
    ON m.person_id = cd.person_id
    WHERE ml.scale IN ('minicog', 'moca', 'mmse')
    --AND m.value_as_number IS NOT NULL  -- We should handle this case by using the measurement_lookup values
    AND m.measurement_date >= cd.index_date -- Ensures a cognitive assessment occurs after cohort entry
),
 
-- Final Cohort
SELECT
    cs.person_id,
    cd.index_date,
    cd.diagnosis_type,
    --AVG(cs.value_as_number) AS avg_followup_score, -- Average follow-up cognitive score (any patient with >= 1 diagnosis)
    COUNT(cs.value_as_number) AS total_tests_after_index, -- Total number of qualifying cognitive tests after index
    MAX(cs.measurement_date) AS last_test_date, -- Most recent cognitive assessment date
    DATEDIFF(op.observation_period_end_date, cd.index_date) -- Calculates total observatio time after index date
        AS days_of_observation
FROM CognitiveScores cs
JOIN CohortDiagnosis cd 
  ON cs.person_id = cd.person_id
JOIN DrugUsers du 
  ON cs.person_id = du.person_id
JOIN observation_period op 
  ON cs.person_id = op.person_id
GROUP BY 
    cs.person_id, 
    cd.index_date, 
    cd.diagnosis_type, 
    op.observation_period_end_date
HAVING DATEDIFF(op.observation_period_end_date, cd.index_date) >= 180 -- Enforces at least 6 months (180) of observation after index date
--ORDER BY avg_followup_score ASC
LIMIT 100;

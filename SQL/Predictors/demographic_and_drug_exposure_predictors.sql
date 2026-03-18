/* initial iteration of demographic predictor variables. Plan to cleanup and streamline*/
WITH demographic_index AS (
    SELECT
        person_id,
        MIN(condition_start_date) AS index_date
    FROM condition_occurrence
    GROUP BY person_id
),

drug_cohort AS ( --gathers information related to drugs patient has taken
    SELECT
        de.person_id,
        de.drug_concept_id,
        i.index_date,
        (DATEDIFF(de.drug_exposure_end_date, de.drug_exposure_start_date)+1) AS cumulative_days_exposed,

        --rolling windows exposure indicators
        CASE --returns a 1 if patient was exposed between 1 and 30 days from the date their condition was recorded as having begun 
            WHEN de.drug_exposure_start_date <= DATE_ADD(i.index_date, 30)
            AND  de.drug_exposure_end_date   >= i.index_date
            THEN 1 ELSE 0
        END AS exposed_0_30d,
        CASE --returns a 1 if patient was exposed bewteen 31 and 90 days
            WHEN de.drug_exposure_start_date <= DATE_ADD(i.index_date, 90)
            AND  de.drug_exposure_end_date   >= DATE_ADD(i.index_date, 31 )
            THEN 1 ELSE 0
        END AS exposed_31_90d,
        CASE --returns a 1 if patient was exposed bewteen 91 and 180 days
            WHEN de.drug_exposure_start_date <= DATE_ADD(i.index_date, 180)
            AND  de.drug_exposure_end_date   >= DATE_ADD(i.index_date, 91)
            THEN 1 ELSE 0
        END AS exposed_91_180d
        
    FROM drug_exposure de
    INNER JOIN demographic_index i
        ON de.person_id = i.person_id
    WHERE de.drug_exposure_start_date <= DATE_ADD(i.index_date,180)
        AND de.drug_exposure_start_date >= i.index_date
),

drug_cohort_collapsed AS (
    /*Combines exosure columns into a single row of data */
    SELECT
        person_id,
        drug_concept_id,
        index_date,
        SUM(cumulative_days_exposed) AS cumulative_days_exposed,
        MAX(exposed_0_30d) AS exposed_0_30d,
        MAX(exposed_31_90d) AS exposed_31_90d,
        MAX(exposed_91_180d) AS exposed_91_180d
    FROM drug_cohort 
    GROUP BY       
        1,2,3
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
)

SELECT
    
    p.person_id,
    (YEAR(i.index_date) - p.year_of_birth) AS age_at_index, --(...theres definitly a better way to do this...)
    g.concept_name AS sex,
    r.concept_name AS race,
    e.concept_name AS ethnicity,
    i.index_date, --date of diagnosis
    dcc.drug_concept_id,
    dh.ingredient_level, 
    dh.component_level,
    dh.brand_level,
    dcc.cumulative_days_exposed, --total days exposed to drug, where initial dosage counts as 1 day
    dcc.exposed_0_30d,
    dcc.exposed_31_90d,
    dcc.exposed_91_180d
FROM person p
-- joins above calculated tables together 
INNER JOIN demographic_index i  
    ON p.person_id = i.person_id
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
WHERE
    --filters out where concept data may be incomplete 
    LOWER(g.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(r.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(e.concept_name) NOT LIKE '%no matching concept%'
ORDER BY 
    ingredient_level,
    p.person_id

LIMIT 100; --limited to save on query time
WITH demographic_index AS (
    SELECT
        person_id,
        MIN(condition_start_date) AS index_date
    FROM condition_occurrence
    GROUP BY person_id
)
SELECT
    p.person_id,
    (YEAR(i.index_date) - p.year_of_birth) AS age_at_index,
    g.concept_name AS sex,
    r.concept_name AS race,
    e.concept_name AS ethnicity,
    i.index_date
FROM person p
INNER JOIN demographic_index i ON p.person_id = i.person_id
LEFT JOIN concept g ON p.gender_concept_id = g.concept_id
LEFT JOIN concept r ON p.race_concept_id = r.concept_id
LEFT JOIN concept e ON p.ethnicity_concept_id = e.concept_id
WHERE 
    LOWER(g.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(r.concept_name) NOT LIKE '%no matching concept%' AND
    LOWER(e.concept_name) NOT LIKE '%no matching concept%';

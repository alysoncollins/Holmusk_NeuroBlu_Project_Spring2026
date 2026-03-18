--return all outcome results as a standardized cutoff score
SELECT 
CASE
    when m.value_as_number = 3 then 0
    when m.value_as_number < 3 then -(3 - m.value_as_number) / 3
    when m.value_as_number > 3 then (m.value_as_number - 3) / (5-3)
    ELSE NULL
END AS CutoffScore,
m.value_as_number,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE m.measurement_concept_id = 37017073 and m.value_as_number is not null

UNION

SELECT 
CASE
    when m.value_as_number = 24 then 0
    when m.value_as_number < 24 then -(24 - m.value_as_number) / 24
    when m.value_as_number > 24 then (m.value_as_number - 24) / (30-24)
    ELSE NULL
END AS CutoffScore,
m.value_as_number,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE m.measurement_concept_id = 4169175 and m.value_as_number is not null

UNION 

--return MOCA results as a cutoff relative score
SELECT 
CASE
    when m.value_as_number = 26 then 0
    when m.value_as_number < 26 then -(26 - m.value_as_number) / 26
    when m.value_as_number > 26 then (m.value_as_number - 26) / (30-26)
    ELSE NULL
END AS CutoffScore,
m.value_as_number,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE m.measurement_concept_id = 44808666 and m.value_as_number is not null

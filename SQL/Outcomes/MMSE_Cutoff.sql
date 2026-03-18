--return mmse results as a cutoff relative score
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
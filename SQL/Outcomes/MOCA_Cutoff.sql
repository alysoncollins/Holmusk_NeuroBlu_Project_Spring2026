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
WHERE ml.scale = 'moca' and m.value_as_number is not null
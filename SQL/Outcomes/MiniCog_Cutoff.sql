--return Mini Cog results as a cutoff relative score
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
WHERE ml.scale = 'minicog' and m.value_as_number is not null
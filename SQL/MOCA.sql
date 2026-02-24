--return moca tests
SELECT m.value_as_number,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE m.measurement_concept_id = 44808666

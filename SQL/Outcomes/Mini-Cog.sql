--return minicog results as a percentage
SELECT m.value_as_number / 5 * 100 as PercentScore,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE m.measurement_concept_id = 37017073 and m.value_as_number is not null

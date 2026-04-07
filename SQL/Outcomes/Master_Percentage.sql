--return all tests as a percentage
--Moca
SELECT m.value_as_number / 30 * 100 as PercentScore,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE ml.scale = 'moca' and m.value_as_number is not null

UNION

--Mini Cog
SELECT m.value_as_number / 5 * 100 as PercentScore,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE ml.scale = 'minicog' and m.value_as_number is not null

UNION

--MMSE
SELECT m.value_as_number / 30 * 100 as PercentScore,
ml.concept_name,
m.measurement_datetime,
m.patient_id
FROM measurement m
JOIN measurement_lookup ml
ON m.measurement_concept_id = ml.measurement_concept_id
WHERE ml.scale = 'mmse' and m.value_as_number is not null

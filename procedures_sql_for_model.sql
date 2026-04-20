WITH procedures AS (
    SELECT patient_id, procedure_concept_id, procedure_date
    FROM procedure_occurrence
    WHERE procedure_concept_id IN (
        '2211329', '2211328', '2211327', '2211332', '2211330',
        '2211353','2211351','2211719','2212018','2212056','2212053'
    )
),
labs AS (
    SELECT DISTINCT
        patient_id,
        MAX(measurement_date) AS most_recent_measurement
    FROM measurement
    WHERE measurement_concept_id IN (
        '3003722','3050174','3043102','42868556','1469579',
        '1092155','1259491','3011498','3029139','3042151',
        '1761505','1617650','1616613','3042810','42868555','1617024'
    )
    GROUP BY patient_id
)

SELECT
    p.patient_id,

    -- CONCEPT: 2211329 computed tomography, head or brain; without contrast material, followed by contrast material(s) and further sections
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211329'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211329,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211329'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211329,

    -- CONCEPT: 2211328 computed tomography, head or brain; with contrast material(s)
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211328'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211328,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211328'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211328,

    -- CONCEPT: 2211327 computed tomography, head or brain; without contrast material
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211327'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211327,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211327'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211327,

    -- CONCEPT: 2211332 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material, followed by contrast material(s) and further sections	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211332'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211332,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211332'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211332,

    -- CONCEPT: 2211330 computed tomography, orbit, sella, or posterior fossa or outer, middle, or inner ear; without contrast material
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211330'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211330,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211330'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211330,

    -- CONCEPT: 2211353 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material, followed by contrast material(s) and further sequences	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211353'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211353,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211353'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211353,


    -- CONCEPT: 2211351 magnetic resonance (eg, proton) imaging, brain (including brain stem); without contrast material	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211351'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211351,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211351'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211351,

    -- CONCEPT: 2211719 magnetic resonance spectroscopy	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2211719'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2211719,

    MAX(CASE
        WHEN p.procedure_concept_id = '2211719'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2211719,

    -- CONCEPT: 2212018 brain imaging, positron emission tomography (pet); metabolic evaluation	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2212018'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2212018,

    MAX(CASE
        WHEN p.procedure_concept_id = '2212018'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2212018,

    -- CONCEPT: 2212056 positron emission tomography (pet) with concurrently acquired computed tomography (ct) for attenuation correction and anatomical localization imaging; limited area (eg, chest, head/neck)	
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2212056'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2212056,

    MAX(CASE
        WHEN p.procedure_concept_id = '2212056'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2212056,

    -- CONCEPT: 2212053 positron emission tomography (pet) imaging; limited area (eg, chest, head/neck)
    COUNT(DISTINCT CASE
        WHEN p.procedure_concept_id = '2212053'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_date
    END) AS procedure_count_180d_2212053,

    MAX(CASE
        WHEN p.procedure_concept_id = '2212053'
         AND p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 ELSE 0
    END) AS procedure_within_90d_2212053

FROM procedures p
JOIN labs l ON p.patient_id = l.patient_id   -- FIX: was comma join with no condition
GROUP BY p.patient_id
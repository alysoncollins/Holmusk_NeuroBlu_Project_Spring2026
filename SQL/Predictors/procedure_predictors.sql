WITH procedures AS ( --pulls data drom procedure_occurrence table
    SELECT patient_id, procedure_concept_id, procedure_date
    FROM procedure_occurrence
    WHERE procedure_concept_id IN (
    '2211329', '2211328', '2211327', '2211332', '2211330',
    '2211353','2211351','2211719','2212018','2212056','2212053'
    )
),
labs AS ( --pulls most recent measurement date from measurement table
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
    /*returns count of distinct procedures within
    180 days from their most recent measurementd date*/
    COUNT(DISTINCT CASE 
        WHEN p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 180)
        THEN p.procedure_concept_id 
    END) AS procedure_group_count_last_180_days,
    /*returns either a 1, present, or 0, absent, 
    depending on if there have been any procedures
    in the past 90 days from the most recent measurement*/
    MAX(CASE 
        WHEN p.procedure_date <= l.most_recent_measurement
         AND p.procedure_date >= DATE_SUB(l.most_recent_measurement, 90)
        THEN 1 --present
        ELSE 0 --absent
    END) AS procedure_within_90_days

FROM procedures p, labs l
GROUP BY p.patient_id

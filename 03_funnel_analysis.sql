-- ============================================================
-- 03_funnel_analysis.sql — Funnel engine
-- Ordered funnel: a step only counts if it happened AFTER the
-- previous step (strict sequential funnel, the industry norm).
-- ============================================================

-- ------------------------------------------------------------
-- Q1. USER-LEVEL FUNNEL PROGRESSION (the core building block)
-- One row per user with the timestamp they reached each step,
-- enforcing step order. Everything else builds on this CTE.
-- ------------------------------------------------------------
WITH step1 AS (
    SELECT user_id, MIN(event_time) AS t1
    FROM events WHERE event_name = 'signup'
    GROUP BY user_id
),
step2 AS (
    SELECT e.user_id, MIN(e.event_time) AS t2
    FROM events e JOIN step1 s ON s.user_id = e.user_id
    WHERE e.event_name = 'onboarding_complete' AND e.event_time >= s.t1
    GROUP BY e.user_id
),
step3 AS (
    SELECT e.user_id, MIN(e.event_time) AS t3
    FROM events e JOIN step2 s ON s.user_id = e.user_id
    WHERE e.event_name = 'project_created' AND e.event_time >= s.t2
    GROUP BY e.user_id
),
step4 AS (
    SELECT e.user_id, MIN(e.event_time) AS t4
    FROM events e JOIN step3 s ON s.user_id = e.user_id
    WHERE e.event_name = 'upgraded_to_paid' AND e.event_time >= s.t3
    GROUP BY e.user_id
),
user_funnel AS (
    SELECT s1.user_id, s1.t1, s2.t2, s3.t3, s4.t4
    FROM step1 s1
    LEFT JOIN step2 s2 USING (user_id)
    LEFT JOIN step3 s3 USING (user_id)
    LEFT JOIN step4 s4 USING (user_id)
)

-- ------------------------------------------------------------
-- Q2. OVERALL FUNNEL: counts, step conversion, drop-off,
--     and cumulative conversion from the top of the funnel
-- ------------------------------------------------------------
, funnel_counts AS (
    SELECT
        COUNT(t1) AS signed_up,
        COUNT(t2) AS onboarded,
        COUNT(t3) AS created_project,
        COUNT(t4) AS upgraded
    FROM user_funnel
)
SELECT step, users,
       ROUND(100.0 * users / FIRST_VALUE(users) OVER (ORDER BY step_order), 1)
           AS pct_of_top,
       ROUND(100.0 * users / LAG(users) OVER (ORDER BY step_order), 1)
           AS step_conversion_pct,
       LAG(users) OVER (ORDER BY step_order) - users
           AS dropped_users
FROM funnel_counts,
LATERAL (VALUES
    (1, '1. signup',              signed_up),
    (2, '2. onboarding_complete', onboarded),
    (3, '3. project_created',     created_project),
    (4, '4. upgraded_to_paid',    upgraded)
) AS v(step_order, step, users)
ORDER BY step_order;

-- ------------------------------------------------------------
-- Q3. FUNNEL SEGMENTED BY ACQUISITION CHANNEL
-- Which channel actually converts, not just which brings volume
-- ------------------------------------------------------------
WITH step1 AS (
    SELECT user_id, MIN(event_time) AS t1 FROM events
    WHERE event_name = 'signup' GROUP BY user_id
),
step2 AS (
    SELECT e.user_id, MIN(e.event_time) AS t2
    FROM events e JOIN step1 s USING (user_id)
    WHERE e.event_name = 'onboarding_complete' AND e.event_time >= s.t1
    GROUP BY e.user_id
),
step3 AS (
    SELECT e.user_id, MIN(e.event_time) AS t3
    FROM events e JOIN step2 s USING (user_id)
    WHERE e.event_name = 'project_created' AND e.event_time >= s.t2
    GROUP BY e.user_id
),
step4 AS (
    SELECT e.user_id, MIN(e.event_time) AS t4
    FROM events e JOIN step3 s USING (user_id)
    WHERE e.event_name = 'upgraded_to_paid' AND e.event_time >= s.t3
    GROUP BY e.user_id
)
SELECT
    u.acquisition_channel,
    COUNT(s1.user_id)                                        AS signed_up,
    COUNT(s2.user_id)                                        AS onboarded,
    COUNT(s3.user_id)                                        AS created_project,
    COUNT(s4.user_id)                                        AS upgraded,
    ROUND(100.0 * COUNT(s2.user_id) / COUNT(s1.user_id), 1)  AS onboard_pct,
    ROUND(100.0 * COUNT(s4.user_id) / COUNT(s1.user_id), 1)  AS signup_to_paid_pct
FROM users u
JOIN step1 s1 USING (user_id)
LEFT JOIN step2 s2 USING (user_id)
LEFT JOIN step3 s3 USING (user_id)
LEFT JOIN step4 s4 USING (user_id)
GROUP BY u.acquisition_channel
ORDER BY signup_to_paid_pct DESC;

-- ------------------------------------------------------------
-- Q4. TIME-TO-CONVERT BETWEEN STEPS (median + p90)
-- How long users take to move through the funnel
-- ------------------------------------------------------------
WITH step1 AS (
    SELECT user_id, MIN(event_time) AS t1 FROM events
    WHERE event_name = 'signup' GROUP BY user_id
),
step2 AS (
    SELECT e.user_id, MIN(e.event_time) AS t2
    FROM events e JOIN step1 s USING (user_id)
    WHERE e.event_name = 'onboarding_complete' AND e.event_time >= s.t1
    GROUP BY e.user_id
),
step3 AS (
    SELECT e.user_id, MIN(e.event_time) AS t3
    FROM events e JOIN step2 s USING (user_id)
    WHERE e.event_name = 'project_created' AND e.event_time >= s.t2
    GROUP BY e.user_id
),
step4 AS (
    SELECT e.user_id, MIN(e.event_time) AS t4
    FROM events e JOIN step3 s USING (user_id)
    WHERE e.event_name = 'upgraded_to_paid' AND e.event_time >= s.t3
    GROUP BY e.user_id
),
gaps AS (
    SELECT 'signup -> onboarding'  AS transition,
           EXTRACT(EPOCH FROM (t2 - t1)) / 3600.0 AS hours
    FROM step1 JOIN step2 USING (user_id)
    UNION ALL
    SELECT 'onboarding -> project',
           EXTRACT(EPOCH FROM (t3 - t2)) / 3600.0
    FROM step2 JOIN step3 USING (user_id)
    UNION ALL
    SELECT 'project -> paid',
           EXTRACT(EPOCH FROM (t4 - t3)) / 3600.0
    FROM step3 JOIN step4 USING (user_id)
)
SELECT
    transition,
    COUNT(*)                                              AS users,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours), 1) AS median_hours,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY hours), 1) AS p90_hours
FROM gaps
GROUP BY transition
ORDER BY transition;

-- ------------------------------------------------------------
-- Q5. WINDOWED FUNNEL: conversion within N days of signup
-- (e.g. "did they upgrade within 30 days?" — comparable across
-- cohorts because every user gets the same window)
-- ------------------------------------------------------------
WITH s AS (
    SELECT user_id, MIN(event_time) AS signup_at
    FROM events WHERE event_name = 'signup' GROUP BY user_id
)
SELECT
    ROUND(100.0 * COUNT(DISTINCT CASE
        WHEN e.event_name = 'onboarding_complete'
         AND e.event_time <= s.signup_at + INTERVAL 7 DAY
        THEN e.user_id END) / COUNT(DISTINCT s.user_id), 1) AS onboarded_within_7d_pct,
    ROUND(100.0 * COUNT(DISTINCT CASE
        WHEN e.event_name = 'upgraded_to_paid'
         AND e.event_time <= s.signup_at + INTERVAL 30 DAY
        THEN e.user_id END) / COUNT(DISTINCT s.user_id), 1) AS paid_within_30d_pct
FROM s
LEFT JOIN events e USING (user_id);

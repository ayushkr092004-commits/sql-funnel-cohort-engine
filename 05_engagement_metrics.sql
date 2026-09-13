-- ============================================================
-- 05_engagement_metrics.sql — DAU / WAU / MAU & stickiness
-- ============================================================

-- ------------------------------------------------------------
-- Q1. MONTHLY MAU + DAU/MAU stickiness ratio
-- ------------------------------------------------------------
WITH daily AS (
    SELECT DISTINCT DATE_TRUNC('day', event_time) AS d, user_id
    FROM events WHERE event_name = 'session_start'
),
dau AS (
    SELECT d, COUNT(*) AS dau FROM daily GROUP BY d
),
mau AS (
    SELECT DATE_TRUNC('month', d) AS m, COUNT(DISTINCT user_id) AS mau
    FROM daily GROUP BY 1
)
SELECT
    m.m AS month,
    m.mau,
    ROUND(AVG(dau.dau), 0)                    AS avg_dau,
    ROUND(100.0 * AVG(dau.dau) / m.mau, 1)    AS stickiness_pct   -- DAU/MAU
FROM mau m
JOIN dau ON DATE_TRUNC('month', dau.d) = m.m
GROUP BY m.m, m.mau
ORDER BY m.m;

-- ------------------------------------------------------------
-- Q2. ROLLING 7-DAY ACTIVE USERS (trend line)
-- ------------------------------------------------------------
WITH daily AS (
    SELECT DISTINCT DATE_TRUNC('day', event_time) AS d, user_id
    FROM events WHERE event_name = 'session_start'
),
calendar AS (
    SELECT DISTINCT d FROM daily
)
SELECT
    c.d AS day,
    COUNT(DISTINCT da.user_id) AS wau_rolling_7d
FROM calendar c
JOIN daily da
  ON da.d BETWEEN c.d - INTERVAL 6 DAY AND c.d
GROUP BY c.d
ORDER BY c.d;

-- ------------------------------------------------------------
-- Q3. POWER-USER CURVE: distribution of active days per month
-- (How many users were active 1 day, 2 days, ... 28+ days)
-- ------------------------------------------------------------
WITH per_user AS (
    SELECT
        user_id,
        DATE_TRUNC('month', event_time) AS m,
        COUNT(DISTINCT DATE_TRUNC('day', event_time)) AS active_days
    FROM events
    WHERE event_name = 'session_start'
    GROUP BY 1, 2
)
SELECT
    LEAST(active_days, 28) AS active_days_bucket,
    COUNT(*)               AS user_months,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM per_user
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- 04_cohort_retention.sql — Cohort retention engine
-- Cohort = the month (or week) a user signed up.
-- Retention = user fired any session_start in month N after signup.
-- ============================================================

-- ------------------------------------------------------------
-- Q1. MONTHLY COHORT RETENTION (long format)
-- The canonical cohort table: cohort_month × month_number × pct
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT user_id, DATE_TRUNC('month', signup_date) AS cohort_month
    FROM users
),
activity AS (
    -- signup itself counts as activity, so M0 retention = 100% by definition
    SELECT DISTINCT
        e.user_id,
        DATE_TRUNC('month', e.event_time) AS active_month
    FROM events e
    WHERE e.event_name IN ('session_start', 'signup')
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS n_users
    FROM cohorts GROUP BY cohort_month
)
SELECT
    c.cohort_month,
    DATEDIFF('month', c.cohort_month, a.active_month) AS month_number,
    COUNT(DISTINCT a.user_id)                         AS active_users,
    cs.n_users                                        AS cohort_size,
    ROUND(100.0 * COUNT(DISTINCT a.user_id) / cs.n_users, 1) AS retention_pct
FROM cohorts c
JOIN activity a USING (user_id)
JOIN cohort_size cs USING (cohort_month)
WHERE a.active_month >= c.cohort_month
GROUP BY c.cohort_month, month_number, cs.n_users
ORDER BY c.cohort_month, month_number;

-- ------------------------------------------------------------
-- Q2. RETENTION MATRIX (pivoted "triangle" view, M0–M6)
-- The classic layout analysts screenshot into decks
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT user_id, DATE_TRUNC('month', signup_date) AS cohort_month
    FROM users
),
activity AS (
    SELECT DISTINCT e.user_id, DATE_TRUNC('month', e.event_time) AS active_month
    FROM events e WHERE e.event_name IN ('session_start', 'signup')
),
retained AS (
    SELECT
        c.cohort_month,
        a.user_id,
        DATEDIFF('month', c.cohort_month, a.active_month) AS m
    FROM cohorts c JOIN activity a USING (user_id)
    WHERE a.active_month >= c.cohort_month
),
size AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM cohorts GROUP BY cohort_month
)
SELECT
    r.cohort_month,
    s.cohort_size,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 1 THEN user_id END) / s.cohort_size, 1) AS m1,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 2 THEN user_id END) / s.cohort_size, 1) AS m2,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 3 THEN user_id END) / s.cohort_size, 1) AS m3,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 4 THEN user_id END) / s.cohort_size, 1) AS m4,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 5 THEN user_id END) / s.cohort_size, 1) AS m5,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN m = 6 THEN user_id END) / s.cohort_size, 1) AS m6
FROM retained r
JOIN size s USING (cohort_month)
GROUP BY r.cohort_month, s.cohort_size
ORDER BY r.cohort_month;

-- ------------------------------------------------------------
-- Q3. WEEKLY RETENTION, FIRST 8 WEEKS (early-lifecycle health)
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT user_id, DATE_TRUNC('week', signup_date) AS cohort_week
    FROM users
),
activity AS (
    SELECT DISTINCT e.user_id, DATE_TRUNC('week', e.event_time) AS active_week
    FROM events e WHERE e.event_name IN ('session_start', 'signup')
),
per_cohort AS (
    SELECT
        c.cohort_week,
        DATEDIFF('week', c.cohort_week, a.active_week) AS week_number,
        COUNT(DISTINCT a.user_id)                      AS active_users
    FROM cohorts c
    JOIN activity a USING (user_id)
    WHERE a.active_week >= c.cohort_week
      AND DATEDIFF('week', c.cohort_week, a.active_week) <= 8
      -- only cohorts old enough to have data for this week_number
      AND c.cohort_week + INTERVAL (7 * DATEDIFF('week', c.cohort_week, a.active_week)) DAY
            <= (SELECT MAX(active_week) FROM activity)
    GROUP BY 1, 2
),
cohort_size AS (
    SELECT cohort_week, COUNT(*) AS n_users FROM cohorts GROUP BY cohort_week
)
SELECT
    p.week_number,
    SUM(p.active_users)                                   AS active_users,
    SUM(s.n_users)                                        AS eligible_cohort_users,
    ROUND(100.0 * SUM(p.active_users) / SUM(s.n_users), 1) AS blended_retention_pct
FROM per_cohort p
JOIN cohort_size s USING (cohort_week)
GROUP BY p.week_number
ORDER BY p.week_number;

-- ------------------------------------------------------------
-- Q4. USER LIFECYCLE STATES: new / retained / resurrected / churned
-- Month-over-month growth accounting
-- ------------------------------------------------------------
WITH monthly_active AS (
    SELECT DISTINCT user_id, DATE_TRUNC('month', event_time) AS m
    FROM events WHERE event_name = 'session_start'
),
labeled AS (
    SELECT
        user_id, m,
        LAG(m) OVER (PARTITION BY user_id ORDER BY m) AS prev_m,
        MIN(m) OVER (PARTITION BY user_id)            AS first_m
    FROM monthly_active
)
SELECT
    m AS month,
    COUNT(CASE WHEN m = first_m THEN 1 END)                                   AS new_users,
    COUNT(CASE WHEN prev_m = m - INTERVAL 1 MONTH THEN 1 END)                 AS retained_users,
    COUNT(CASE WHEN m <> first_m
               AND (prev_m IS NULL OR prev_m < m - INTERVAL 1 MONTH) THEN 1 END) AS resurrected_users
FROM labeled
GROUP BY m
ORDER BY m;

-- ------------------------------------------------------------
-- Q5. REVENUE RETENTION BY SIGNUP COHORT (cumulative LTV curve)
-- Average revenue per cohort user, accumulated by month since signup
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT user_id, DATE_TRUNC('month', signup_date) AS cohort_month
    FROM users
),
rev AS (
    SELECT
        c.cohort_month,
        DATEDIFF('month', c.cohort_month, DATE_TRUNC('month', o.order_time)) AS m,
        SUM(o.amount_usd) AS revenue
    FROM orders o JOIN cohorts c USING (user_id)
    GROUP BY 1, 2
),
size AS (
    SELECT cohort_month, COUNT(*) AS n FROM cohorts GROUP BY cohort_month
)
SELECT
    r.cohort_month,
    r.m AS month_number,
    ROUND(SUM(r.revenue) OVER (PARTITION BY r.cohort_month ORDER BY r.m)
          / s.n, 2) AS cumulative_revenue_per_user
FROM rev r JOIN size s USING (cohort_month)
ORDER BY r.cohort_month, r.m;

-- ------------------------------------------------------------
-- Q6. RETENTION BY ACQUISITION CHANNEL (M1 and M3 side by side)
-- Answers: which channel brings users who stick?
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT u.user_id, u.acquisition_channel,
           DATE_TRUNC('month', u.signup_date) AS cohort_month
    FROM users u
),
activity AS (
    SELECT DISTINCT e.user_id, DATE_TRUNC('month', e.event_time) AS active_month
    FROM events e WHERE e.event_name = 'session_start'
)
SELECT
    c.acquisition_channel,
    COUNT(DISTINCT c.user_id) AS users,
    ROUND(100.0 * COUNT(DISTINCT CASE
        WHEN DATEDIFF('month', c.cohort_month, a.active_month) = 1
        THEN a.user_id END) / COUNT(DISTINCT c.user_id), 1) AS m1_retention_pct,
    ROUND(100.0 * COUNT(DISTINCT CASE
        WHEN DATEDIFF('month', c.cohort_month, a.active_month) = 3
        THEN a.user_id END) / COUNT(DISTINCT c.user_id), 1) AS m3_retention_pct
FROM cohorts c
LEFT JOIN activity a USING (user_id)
GROUP BY c.acquisition_channel
ORDER BY m1_retention_pct DESC;

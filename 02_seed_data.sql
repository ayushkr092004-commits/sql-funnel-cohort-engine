-- ============================================================
-- 02_seed_data.sql — Synthetic but realistic data, pure SQL
-- Generates ~2,000 users, a probabilistic 4-step funnel,
-- decaying engagement events, and paid orders.
-- Dialect: DuckDB (see README for the Postgres variant notes)
-- ============================================================

-- Reproducible randomness
SELECT setseed(0.42);

-- ------------------------------------------------------------
-- 1. USERS — 2,000 signups spread over Jan–Dec 2025
-- ------------------------------------------------------------
INSERT INTO users
SELECT
    i AS user_id,
    DATE '2025-01-01' + INTERVAL (CAST(floor(random() * 365) AS INT)) DAY AS signup_date,
    CASE CAST(floor(random() * 100) AS INT)
        WHEN 0 THEN 'referral'  -- keep tiny buckets possible
        ELSE CASE
            WHEN random() < 0.35 THEN 'organic'
            WHEN random() < 0.55 THEN 'paid_search'
            WHEN random() < 0.75 THEN 'social'
            WHEN random() < 0.90 THEN 'referral'
            ELSE 'email'
        END
    END AS acquisition_channel,
    CASE
        WHEN random() < 0.50 THEN 'web'
        WHEN random() < 0.80 THEN 'ios'
        ELSE 'android'
    END AS device,
    CASE
        WHEN random() < 0.40 THEN 'US'
        WHEN random() < 0.60 THEN 'IN'
        WHEN random() < 0.75 THEN 'GB'
        WHEN random() < 0.90 THEN 'DE'
        ELSE 'BR'
    END AS country
FROM generate_series(1, 2000) AS t(i);

-- ------------------------------------------------------------
-- 2. FUNNEL EVENTS
--    Every user fires `signup`. Later steps happen with
--    channel-dependent probability and a realistic delay.
-- ------------------------------------------------------------

-- Per-user dice rolls, computed once so steps nest correctly
CREATE TEMP TABLE _funnel AS
SELECT
    u.user_id,
    u.signup_date,
    u.acquisition_channel,
    random() AS r_onb,
    random() AS r_proj,
    random() AS r_paid,
    CAST(floor(random() * 3)  AS INT) AS d_onb,    -- 0–2 days after signup
    CAST(floor(random() * 7)  AS INT) AS d_proj,   -- 0–6 days after onboarding
    CAST(floor(random() * 30) AS INT) AS d_paid    -- 0–29 days after project
FROM users u;

-- Step 1: signup (100%)
INSERT INTO events
SELECT
    user_id * 10 + 1 AS event_id,
    user_id,
    'signup',
    CAST(signup_date AS TIMESTAMP) + INTERVAL (CAST(floor(random()*86400) AS INT)) SECOND
FROM _funnel;

-- Step 2: onboarding_complete (~72%, referral converts best)
INSERT INTO events
SELECT
    user_id * 10 + 2,
    user_id,
    'onboarding_complete',
    CAST(signup_date + INTERVAL (d_onb) DAY AS TIMESTAMP)
        + INTERVAL (CAST(floor(random()*86400) AS INT)) SECOND
FROM _funnel
WHERE r_onb < CASE acquisition_channel
                  WHEN 'referral' THEN 0.82
                  WHEN 'organic'  THEN 0.76
                  WHEN 'email'    THEN 0.72
                  ELSE 0.65 END;

-- Step 3: project_created (~60% of step 2)
INSERT INTO events
SELECT
    user_id * 10 + 3,
    user_id,
    'project_created',
    CAST(signup_date + INTERVAL (d_onb + d_proj) DAY AS TIMESTAMP)
        + INTERVAL (CAST(floor(random()*86400) AS INT)) SECOND
FROM _funnel
WHERE r_onb < CASE acquisition_channel
                  WHEN 'referral' THEN 0.82
                  WHEN 'organic'  THEN 0.76
                  WHEN 'email'    THEN 0.72
                  ELSE 0.65 END
  AND r_proj < 0.60;

-- Step 4: upgraded_to_paid (~35% of step 3)
INSERT INTO events
SELECT
    user_id * 10 + 4,
    user_id,
    'upgraded_to_paid',
    CAST(signup_date + INTERVAL (d_onb + d_proj + d_paid) DAY AS TIMESTAMP)
        + INTERVAL (CAST(floor(random()*86400) AS INT)) SECOND
FROM _funnel
WHERE r_onb < CASE acquisition_channel
                  WHEN 'referral' THEN 0.82
                  WHEN 'organic'  THEN 0.76
                  WHEN 'email'    THEN 0.72
                  ELSE 0.65 END
  AND r_proj < 0.60
  AND r_paid < 0.35;

-- ------------------------------------------------------------
-- 3. ENGAGEMENT EVENTS (session_start) — drive retention
--    Each user gets a hidden "stickiness" score; probability of
--    being active decays with weeks since signup.
-- ------------------------------------------------------------
CREATE TEMP TABLE _stickiness AS
SELECT user_id, signup_date, 0.25 + random() * 0.65 AS stickiness
FROM users;

INSERT INTO events
SELECT
    2000 * 100000 + s.user_id * 400 + gs.d AS event_id,
    s.user_id,
    'session_start',
    CAST(s.signup_date + INTERVAL (gs.d) DAY AS TIMESTAMP)
        + INTERVAL (CAST(floor(random()*86400) AS INT)) SECOND
FROM _stickiness s
CROSS JOIN generate_series(0, 364) AS gs(d)
WHERE s.signup_date + INTERVAL (gs.d) DAY <= DATE '2025-12-31'
  -- daily activity probability = stickiness * exp(-weeks/6), small floor
  AND random() < GREATEST(0.002, s.stickiness * exp(-(gs.d / 7.0) / 6.0) * 0.12);

-- ------------------------------------------------------------
-- 4. ORDERS — paid users buy monthly-ish subscriptions
-- ------------------------------------------------------------
INSERT INTO orders
SELECT
    ROW_NUMBER() OVER () AS order_id,
    p.user_id,
    p.first_paid + INTERVAL (m.m) MONTH AS order_time,
    CASE WHEN random() < 0.8 THEN 29.00 ELSE 99.00 END AS amount_usd
FROM (
    SELECT user_id, MIN(event_time) AS first_paid
    FROM events WHERE event_name = 'upgraded_to_paid'
    GROUP BY user_id
) p
CROSS JOIN generate_series(0, 11) AS m(m)
WHERE p.first_paid + INTERVAL (m.m) MONTH <= TIMESTAMP '2025-12-31 23:59:59'
  -- ~88% month-over-month subscription survival
  AND random() < POWER(0.88, m.m);

DROP TABLE _funnel;
DROP TABLE _stickiness;

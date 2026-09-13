-- ============================================================
-- Product Funnel & Cohort Retention Analysis Engine
-- 01_schema.sql — Core tables
-- Dialect: ANSI SQL (tested on DuckDB; Postgres-compatible)
-- ============================================================

DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

-- ------------------------------------------------------------
-- USERS: one row per registered user
-- ------------------------------------------------------------
CREATE TABLE users (
    user_id             INTEGER PRIMARY KEY,
    signup_date         DATE        NOT NULL,
    acquisition_channel VARCHAR(30) NOT NULL,   -- organic | paid_search | social | referral | email
    device              VARCHAR(20) NOT NULL,   -- web | ios | android
    country             VARCHAR(2)  NOT NULL
);

-- ------------------------------------------------------------
-- EVENTS: append-only product event stream
--   Funnel steps (in order):
--     1. signup
--     2. onboarding_complete
--     3. project_created
--     4. upgraded_to_paid
--   Plus generic engagement events:
--     session_start  (used for retention / DAU / MAU)
-- ------------------------------------------------------------
CREATE TABLE events (
    event_id    BIGINT      PRIMARY KEY,
    user_id     INTEGER     NOT NULL REFERENCES users(user_id),
    event_name  VARCHAR(40) NOT NULL,
    event_time  TIMESTAMP   NOT NULL
);

-- ------------------------------------------------------------
-- ORDERS: monetization events (for revenue retention)
-- ------------------------------------------------------------
CREATE TABLE orders (
    order_id    BIGINT    PRIMARY KEY,
    user_id     INTEGER   NOT NULL REFERENCES users(user_id),
    order_time  TIMESTAMP NOT NULL,
    amount_usd  DECIMAL(10,2) NOT NULL
);

CREATE INDEX idx_events_user_time ON events(user_id, event_time);
CREATE INDEX idx_events_name      ON events(event_name);
CREATE INDEX idx_orders_user      ON orders(user_id);

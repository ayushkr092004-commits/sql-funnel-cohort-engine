# Product Funnel & Cohort Retention Analysis Engine

A pure-SQL analytics project that answers the two questions every product team asks: **where do users drop off** (funnel analysis) and **do the users we acquire actually stick around** (cohort retention). It ships with a synthetic-but-realistic event dataset generated entirely in SQL, so the whole project is reproducible from five script files.

## What it demonstrates

- Strict **sequential funnel logic** — a step only counts if it happened *after* the previous step, using nested `MIN(event_time)` CTEs rather than naive event counting.
- **Cohort retention** in three flavors: long-format table, the classic pivoted M1–M6 retention matrix, and a blended weekly curve that correctly excludes cohorts too young to have data (avoiding survivorship bias in the denominator).
- **Growth accounting** — classifying every monthly active user as new, retained, or resurrected with window functions (`LAG`, `MIN() OVER`).
- **Revenue retention / LTV curves** — cumulative revenue per cohort user via a windowed running sum.
- **Engagement metrics** — DAU/MAU stickiness, rolling 7-day actives, and a power-user curve.
- **Segmentation** — every core analysis is repeated by acquisition channel to show which channels bring users who convert *and* retain, not just volume.
- Time-to-convert distributions using `PERCENTILE_CONT` (median and p90 hours between steps).

## Project structure

| File | Purpose |
|---|---|
| `01_schema.sql` | Tables: `users`, `events` (append-only event stream), `orders` |
| `02_seed_data.sql` | Generates ~2,000 users, a probabilistic 4-step funnel, exponentially decaying engagement, and subscription orders — all in SQL |
| `03_funnel_analysis.sql` | Overall funnel, channel-segmented funnel, time-to-convert, windowed (7-day / 30-day) conversion |
| `04_cohort_retention.sql` | Monthly cohort table, pivoted retention matrix, weekly curve, lifecycle states, revenue retention, retention by channel |
| `05_engagement_metrics.sql` | MAU + stickiness, rolling WAU, power-user curve |
| `run_demo.py` | One-command runner that builds the database and executes every query in DuckDB |

## Data model

```
users (user_id, signup_date, acquisition_channel, device, country)
   │
   ├── events (user_id, event_name, event_time)
   │      funnel:  signup → onboarding_complete → project_created → upgraded_to_paid
   │      engagement: session_start
   │
   └── orders (user_id, order_time, amount_usd)
```

## Quick start

```bash
pip install duckdb
python run_demo.py
```

That creates `funnel.duckdb`, loads the schema and synthetic data, and prints every analysis result. Or open a DuckDB shell and run the files in order yourself.

### Running on PostgreSQL

The analysis files (`03`–`05`) use ANSI SQL and run on Postgres with two small substitutions:

- `DATEDIFF('month', a, b)` → `(EXTRACT(YEAR FROM b) - EXTRACT(YEAR FROM a)) * 12 + (EXTRACT(MONTH FROM b) - EXTRACT(MONTH FROM a))`, or `AGE()`-based math.
- `INTERVAL (expr) DAY` → `(expr || ' days')::interval`.

The seed file `02_seed_data.sql` uses `generate_series` and `random()`, both native to Postgres; only the interval arithmetic above needs the same tweak.

## Sample results (from the seeded data)

**Overall funnel**

| step | users | % of top | step conversion |
|---|---|---|---|
| signup | 2,000 | 100.0 | — |
| onboarding_complete | ~1,300 | ~66 | ~66% |
| project_created | ~790 | ~40 | ~60% |
| upgraded_to_paid | ~280 | ~14 | ~35% |

**Monthly retention matrix** — cohorts hold ~60–70% at M1, decaying to ~5–8% by M6, with `0.0` in cells where the cohort hasn't aged enough yet (the visible "triangle").

## Design notes worth mentioning in an interview

1. **Why the funnel enforces ordering.** Counting users who fired each event independently overstates conversion — a user who upgraded before finishing onboarding shouldn't count as a clean funnel completion. The nested `MIN(event_time) ... WHERE event_time >= previous_step` pattern guarantees sequence.
2. **Why M0 = 100%.** Signup itself counts as activity in the signup month, which is the standard convention — otherwise M0 varies with tracking noise and the matrix is hard to read.
3. **Why the weekly curve filters young cohorts.** A cohort that signed up last week can't show week-4 retention; including it in the denominator would drag the curve down artificially.
4. **Windowed conversion (Q5 in file 03)** makes cohorts comparable: "% paid within 30 days" is fair to both January and December signups, whereas lifetime conversion always favors older cohorts.

## Extension ideas

- Materialize the user-level funnel CTE as a view or dbt model and build the matrix off it.
- Add an A/B test dimension to `users` and compare funnels between variants.
- Swap monthly cohorts for `first_purchase` cohorts to analyze buyer retention.
- Compute Quick Ratio: (new + resurrected) / churned per month from the lifecycle query.

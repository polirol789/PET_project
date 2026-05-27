-- ============================================================
-- CTE 1: БАЗОВА ДЕДУБЛІКАЦІЯ
-- Залишаємо останній snapshot за кожен день для кожного ad_id.
-- Оскільки в сирих даних можуть бути кілька snapshot-ів на день,
-- беремо лише найсвіжіший запис через ROW_NUMBER().
-- ============================================================
WITH deduped AS (
  SELECT
    source,
    ad_id,
    date,
    spend,
    impressions,
    clicks,
    installs,
    registrations,

    ROW_NUMBER() OVER (
      PARTITION BY ad_id, date
      ORDER BY timestamp DESC
    ) AS rn

  FROM `loyal-semiotics-496107-f5.homework_data.marketing_ads_raw`
),

-- ============================================================
-- CTE 2: ФІНАЛЬНІ DAILY SNAPSHOTS
-- ============================================================
final_snapshots AS (
  SELECT
    source,
    ad_id,
    date,
    spend,
    impressions,
    clicks,
    installs,
    registrations
  FROM deduped
  WHERE rn = 1
),

-- ============================================================
-- CTE 3: РОЗРАХУНОК ЩОДЕННИХ ЧИСТИХ ПРИРОСТІВ (ДЕЛЬТИ)
--
-- Дані в таблиці кумулятивні:
-- кожен наступний день містить накопичені значення.
--
-- Тому розгортаємо cumulative metrics у реальні денні показники:
-- від поточного дня віднімаємо попередній день для конкретного ad_id.
-- COALESCE(..., 0) потрібен для першого дня життя оголошення,
-- коли LAG() повертає NULL.
-- ============================================================
daily_increments AS (
  SELECT
    source,
    ad_id,
    date,

    -- Отримуємо місяць для подальшого групування
    DATE_TRUNC(date, MONTH) AS month,

    -- Чисті витрати за день
    spend - COALESCE(
      LAG(spend) OVER (
        PARTITION BY ad_id
        ORDER BY date
      ), 0
    ) AS daily_spend,

    -- Чисті покази за день
    impressions - COALESCE(
      LAG(impressions) OVER (
        PARTITION BY ad_id
        ORDER BY date
      ), 0
    ) AS daily_impressions,

    -- Чисті кліки за день
    clicks - COALESCE(
      LAG(clicks) OVER (
        PARTITION BY ad_id
        ORDER BY date
      ), 0
    ) AS daily_clicks,

    -- Чисті інстали за день
    installs - COALESCE(
      LAG(installs) OVER (
        PARTITION BY ad_id
        ORDER BY date
      ), 0
    ) AS daily_installs,

    -- Чисті реєстрації за день
    registrations - COALESCE(
      LAG(registrations) OVER (
        PARTITION BY ad_id
        ORDER BY date
      ), 0
    ) AS daily_registrations

  FROM final_snapshots
),

-- ============================================================
-- CTE 4: ПОМІСЯЧНА АГРЕГАЦІЯ ПО КАНАЛАХ
--
-- Агрегуємо вже очищені денні дельти по:
--   • source
--   • month
--
-- Тут рахуємо лише базові абсолютні значення.
-- Відносні маркетингові метрики (CTR, CAC, CPM тощо)
-- будемо рахувати окремо в фінальному SELECT.
-- ============================================================
monthly_perf AS (
  SELECT
    source,
    CAST(month AS STRING) AS period,

    ROUND(SUM(daily_spend), 2) AS spend,
    SUM(daily_impressions) AS impressions,
    SUM(daily_clicks) AS clicks,
    SUM(daily_installs) AS installs,
    SUM(daily_registrations) AS registrations

  FROM daily_increments
  GROUP BY source, month
),

-- ============================================================
-- CTE 5: ЗАГАЛЬНИЙ ПІДСУМОК (ALL TIME) ПО КОЖНОМУ КАНАЛУ
--
-- Потрібен для:
--   1. Порівняння CAC між каналами
--   2. Аналізу funnel conversion
--   3. Оцінки ефективності META vs TikTok vs Google
--   4. Розрахунку LTV/CAC
-- ============================================================
total_perf AS (
  SELECT
    source,
    'ALL TIME' AS period,

    ROUND(SUM(daily_spend), 2) AS spend,
    SUM(daily_impressions) AS impressions,
    SUM(daily_clicks) AS clicks,
    SUM(daily_installs) AS installs,
    SUM(daily_registrations) AS registrations

  FROM daily_increments
  GROUP BY source
),

-- ============================================================
-- CTE 6: ОБ'ЄДНАННЯ MONTHLY + ALL TIME
--
-- Створюємо єдиний dataset:
--   • помісячна динаміка
--   • загальні підсумки
--
-- Це дозволяє:
--   • будувати один фінальний report
--   • уникнути дублювання логіки метрик
--   • централізовано рахувати CAC / CTR / CPM / CR
-- ============================================================
combined_report AS (
  SELECT * FROM monthly_perf

  UNION ALL

  SELECT * FROM total_perf
)

-- ============================================================
-- ФІНАЛЬНИЙ REPORT
-- ============================================================
SELECT
  source,
  period,

  -- ── Абсолютні метрики ─────────────────────────────────────
  spend,
  impressions,
  clicks,
  installs,
  registrations,

  -- ── CPM: вартість 1000 показів ────────────────────────────
  ROUND(
    spend / NULLIF(impressions, 0) * 1000
  , 2) AS cpm,

  -- ── CTR: % кліків від показів ─────────────────────────────
  ROUND(
    clicks * 100.0 / NULLIF(impressions, 0)
  , 4) AS ctr_pct,

  -- ── CR Click → Install ────────────────────────────────────
  ROUND(
    installs * 100.0 / NULLIF(clicks, 0)
  , 2) AS cr_click_to_install_pct,

  -- ── CR Install → Registration ─────────────────────────────
  ROUND(
    registrations * 100.0 / NULLIF(installs, 0)
  , 2) AS cr_install_to_reg_pct,

  -- ── CAC: вартість одного зареєстрованого користувача ─────
  ROUND(
    spend / NULLIF(registrations, 0)
  , 2) AS cac,

  -- ── BONUS: LTV/CAC ratio ──────────────────────────────────
  ROUND(
    CASE
      WHEN source = 'TikTok'
        THEN 8.50 / NULLIF(spend / NULLIF(registrations, 0), 0)

      WHEN source = 'META'
        THEN 6.20 / NULLIF(spend / NULLIF(registrations, 0), 0)

      WHEN source = 'Google'
        THEN 12.40 / NULLIF(spend / NULLIF(registrations, 0), 0)

      ELSE NULL
    END
  , 2) AS ltv_cac_ratio

FROM combined_report

-- ============================================================
-- СОРТУВАННЯ:
--   1. Групуємо по source
--   2. Усередині source:
--        • спочатку місяці
--        • потім ALL TIME
-- ============================================================
ORDER BY
  source ASC,

  CASE
    WHEN period = 'ALL TIME' THEN 2
    ELSE 1
  END ASC,

  period ASC;


-- ============================================================
-- TECHNICAL DATA QUALITY CHECK
--
-- Перевірка повноти даних за конкретний місяць.
--
-- Допомагає:
--   • виявити пропущені дні
--   • перевірити повноту ingestion
--   • зрозуміти, чи коректно інтерпретувати monthly CAC
--
-- Запускається окремо при потребі.
-- ============================================================

/*
SELECT
  DATE_TRUNC(date, MONTH) AS month,

  MIN(date) AS first_day,
  MAX(date) AS last_day,

  COUNT(DISTINCT date) AS days_with_data,

  CASE
    WHEN COUNT(DISTINCT date) >= 28
      THEN 'Month looks complete'

    ELSE 'Possible missing days / partial month'
  END AS data_quality_status

FROM `loyal-semiotics-496107-f5.homework_data.marketing_ads_raw`

GROUP BY month
ORDER BY month;
*/

----------------------------------------------------------------------------------------------------------------------------------------------------------------------

--============================================================
-- CTE 1: дедублікація — залишаємо останній snapshot
-- за кожен день для кожного оголошення
--
-- ROW_NUMBER() а не RANK() або DENSE_RANK() — бо нам потрібно
-- рівно 1 рядок на (ad_id, date), навіть якщо два snapshot-и
-- мають однаковий timestamp (edge case — беремо будь-який один)
-- ============================================================
WITH deduped AS (
  SELECT
    source,
    campaign_id,
    adset_id,
    ad_id,
    date,
    spend,
    impressions,
    clicks,
    installs,
    registrations,
    -- партиціонуємо по (ad_id, date) — унікальна комбінація
    -- оголошення за один день
    -- сортуємо DESC щоб останній snapshot отримав rn = 1
    ROW_NUMBER() OVER (
      PARTITION BY ad_id, date
      ORDER BY timestamp DESC
    ) AS rn
  FROM `loyal-semiotics-496107-f5.homework_data.marketing_ads_raw`
),

-- ============================================================
-- CTE 2: денні метрики по (source, date)
-- SUM тут коректний — після дедублікації кожен ad_id
-- зустрічається рівно раз на день, тому підсумовуємо по каналу
-- ============================================================
daily AS (
  SELECT
    source,
    date,
    ROUND(SUM(spend), 2)        AS daily_spend,
    SUM(impressions)            AS daily_impressions,
    SUM(clicks)                 AS daily_clicks,
    SUM(installs)               AS daily_installs,
    SUM(registrations)          AS daily_registrations
  FROM deduped
  WHERE rn = 1
  GROUP BY source, date
)

-- ============================================================
-- CTE 3 + фінальний SELECT: агрегація по source за весь період
-- Всі метрики рахуємо від агрегованих сум — не AVG(daily_rate)
-- бо AVG по ставках дає некоректний результат при нерівних обсягах
-- (наприклад день з 10 показами і день з 100000 мають однакову вагу)
-- ============================================================
SELECT
  source,

  -- ── СИРІ СУМИ ───────────────────────────────────────────
  ROUND(SUM(daily_spend), 2)                                    AS total_spend,
  SUM(daily_impressions)                                        AS total_impressions,
  SUM(daily_clicks)                                             AS total_clicks,
  SUM(daily_installs)                                           AS total_installs,
  SUM(daily_registrations)                                      AS total_registrations,

  -- ── РОЗРАХОВАНІ МЕТРИКИ ──────────────────────────────────

  -- CPM: вартість 1000 показів
  -- показує наскільки дорогий аукціон в цьому каналі
  ROUND(
    SUM(daily_spend) / NULLIF(SUM(daily_impressions), 0) * 1000
  , 2)                                                          AS cpm,

  -- CTR: % кліків від показів
  -- показує наскільки креатив зацікавлює аудиторію
  ROUND(
    SUM(daily_clicks) * 100.0
    / NULLIF(SUM(daily_impressions), 0)
  , 4)                                                          AS ctr_pct,

  -- CR Click→Install: % встановлень від кліків
  -- показує наскільки добре конвертує стор / лендінг після кліку
  ROUND(
    SUM(daily_installs) * 100.0
    / NULLIF(SUM(daily_clicks), 0)
  , 2)                                                          AS cr_click_to_install_pct,

  -- CR Install→Registration: % реєстрацій від встановлень
  -- показує якість трафіку — чи доходять до реєстрації після інсталу
  ROUND(
    SUM(daily_registrations) * 100.0
    / NULLIF(SUM(daily_installs), 0)
  , 2)                                                          AS cr_install_to_reg_pct,

  -- CAC (Cost per Registration): скільки коштує 1 підписник
  -- основна метрика ефективності залучення
  ROUND(
    SUM(daily_spend)
    / NULLIF(SUM(daily_registrations), 0)
  , 2)                                                          AS cac

FROM daily
GROUP BY source
ORDER BY total_spend DESC

----------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- ============================================================
-- Розбивка CAC по місяцях і каналах
-- Базуємось на дедублікованих денних даних з попереднього запиту
-- ============================================================
WITH deduped AS (
  SELECT
    source,
    date,
    spend,
    installs,
    registrations,
    ROW_NUMBER() OVER (
      PARTITION BY ad_id, date
      ORDER BY timestamp DESC
    ) AS rn
  FROM `loyal-semiotics-496107-f5.homework_data.marketing_ads_raw`
),

daily AS (
  SELECT
    source,
    date,
    -- місяць як DATE для зручного сортування
    DATE_TRUNC(date, MONTH)     AS month,
    SUM(spend)                  AS daily_spend,
    SUM(installs)               AS daily_installs,
    SUM(registrations)          AS daily_registrations
  FROM deduped
  WHERE rn = 1
  GROUP BY source, date
)

SELECT
  month,
  source,

  ROUND(SUM(daily_spend), 2)                                    AS monthly_spend,
  SUM(daily_installs)                                           AS monthly_installs,
  SUM(daily_registrations)                                      AS monthly_registrations,

  -- CAC по місяцю: spend цього місяця / реєстрації цього місяця
  ROUND(
    SUM(daily_spend) / NULLIF(SUM(daily_registrations), 0)
  , 2)                                                          AS monthly_cac,

  -- CR Click→Install по місяцю для діагностики змін CAC
  -- якщо CAC росте — перевіряємо чи впала конверсія
  ROUND(
    SUM(daily_installs) * 100.0
    / NULLIF(SUM(daily_registrations), 0)
  , 2)                                                          AS installs_per_reg

FROM daily
GROUP BY month, source
ORDER BY month ASC, source

---------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Чи є дані за весь липень або тільки частина місяця?
SELECT
  MIN(date) AS first_day,
  MAX(date) AS last_day,
  COUNT(DISTINCT date) AS days_with_data
FROM `loyal-semiotics-496107-f5.homework_data.marketing_ads_raw`
WHERE DATE_TRUNC(date, MONTH) = '2024-07-01'


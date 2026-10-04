-- =====================================================================
-- PROJECT: Retail Loan Early-Warning Risk Score (Indian lending context)
-- Database: PostgreSQL (run in pgAdmin Query Tool, one section at a time)
--
-- DATA NOTE: This is a SIMULATED dataset modelled on Indian retail lending
-- (CIBIL score, FOIR, EMI, 90+ DPD default, INR amounts, Indian cities).
-- =====================================================================


-- =====================================================================
-- PART 0: SETUP (run once, in ONE session so setseed works)
-- =====================================================================
DROP TABLE IF EXISTS loans_clean CASCADE;   -- also drops dependent views
DROP TABLE IF EXISTS loans_raw CASCADE;
DROP TABLE IF EXISTS risk_rules CASCADE;

SELECT setseed(0.42);   -- change this number to get your own unique dataset

CREATE TABLE loans_raw (
    loan_id              INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    age                  INT,
    city                 TEXT,
    employment_type      TEXT,
    monthly_income_inr   INT,
    cibil_score          INT,          -- 300-900; NULL / -1 = no credit history
    loan_type            TEXT,
    loan_amount_inr      BIGINT,
    tenure_months        INT,
    interest_rate_pct    NUMERIC(5,2),
    emi_inr              INT,          -- new loan EMI
    existing_emi_inr     INT,          -- EMIs on other loans
    missed_payments_12m  INT,
    defaulted            INT           -- 1 = 90+ days past due (NPA-style), 0 = not
);


-- =====================================================================
-- PART 1: GENERATE 20,000 SIMULATED LOAN RECORDS
-- =====================================================================
INSERT INTO loans_raw
    (age, city, employment_type, monthly_income_inr, cibil_score, loan_type,
     loan_amount_inr, tenure_months, interest_rate_pct, emi_inr,
     existing_emi_inr, missed_payments_12m, defaulted)
WITH base AS (
    SELECT (21 + floor(random() * 40))::int AS age,
           (ARRAY['Mumbai','Delhi NCR','Bengaluru','Pune','Hyderabad','Chennai',
                  'Kolkata','Ahmedabad','Nagpur','Jaipur','Lucknow','Indore',
                  'Surat','Kochi'])[1 + floor(random() * 14)::int] AS city,
           random() AS r_emp,  random() AS r_loan, random() AS r_inc,
           random() AS r_cibil, random() AS r_null, random() AS r_amt,
           random() AS r_ten,  random() AS r_rate, random() AS r_ex,
           random() AS r_miss, random() AS r_def
    FROM generate_series(1, 20000)
),
typed AS (
    SELECT age, city, r_amt, r_ten, r_rate, r_ex, r_miss, r_def,
           CASE WHEN r_emp < 0.55 THEN 'Salaried - Private'
                WHEN r_emp < 0.70 THEN 'Salaried - Govt/PSU'
                WHEN r_emp < 0.88 THEN 'Self-Employed'
                ELSE 'Business Owner' END AS employment_type,
           CASE WHEN r_loan < 0.35 THEN 'Personal Loan'
                WHEN r_loan < 0.55 THEN 'Home Loan'
                WHEN r_loan < 0.70 THEN 'Auto Loan'
                WHEN r_loan < 0.82 THEN 'Two-Wheeler Loan'
                WHEN r_loan < 0.92 THEN 'Education Loan'
                ELSE 'Gold Loan' END AS loan_type,
           (round((15000 + power(r_inc, 2.5) * 185000) / 500) * 500)::int AS inc,
           CASE WHEN r_null < 0.04 THEN NULL      -- ~4% new-to-credit customers
                ELSE least(900, round(500 + 400 * power(r_cibil, 0.5)))::int END AS cibil
    FROM base
),
loaned AS (
    SELECT t.*,
           (round((CASE loan_type
               WHEN 'Personal Loan'    THEN least(1000000,  greatest(50000,   inc * (2 + 10 * r_amt)))
               WHEN 'Home Loan'        THEN least(15000000, greatest(1000000, inc * 12 * (2 + 3 * r_amt)))
               WHEN 'Auto Loan'        THEN least(2000000,  greatest(300000,  inc * 12 * (0.5 + 1.5 * r_amt)))
               WHEN 'Two-Wheeler Loan' THEN least(200000,   greatest(40000,   inc * (2 + 4 * r_amt)))
               WHEN 'Education Loan'   THEN least(4000000,  greatest(300000,  inc * 12 * (0.5 + 2 * r_amt)))
               ELSE                         least(500000,   greatest(30000,   inc * (1 + 5 * r_amt)))
           END) / 1000) * 1000)::bigint AS amt,
           (CASE loan_type
               WHEN 'Personal Loan'    THEN 12 * (1 + floor(r_ten * 5))
               WHEN 'Home Loan'        THEN 120 + 12 * floor(r_ten * 11)
               WHEN 'Auto Loan'        THEN 36 + 12 * floor(r_ten * 5)
               WHEN 'Two-Wheeler Loan' THEN 12 + 12 * floor(r_ten * 3)
               WHEN 'Education Loan'   THEN 60 + 12 * floor(r_ten * 6)
               ELSE                         6 + 3 * floor(r_ten * 3)
           END)::int AS tenure,
           round((CASE loan_type
               WHEN 'Personal Loan'    THEN 10.99 + r_rate * 13
               WHEN 'Home Loan'        THEN 8.75  + r_rate * 1.5
               WHEN 'Auto Loan'        THEN 9.0   + r_rate * 4
               WHEN 'Two-Wheeler Loan' THEN 11.0  + r_rate * 7
               WHEN 'Education Loan'   THEN 9.5   + r_rate * 3.5
               ELSE                         9.0   + r_rate * 3
           END)::numeric, 2) AS rate
    FROM typed t
),
priced AS (
    SELECT l.*,
           -- standard EMI formula: P*r*(1+r)^n / ((1+r)^n - 1), r = monthly rate
           round(amt * (rate / 1200) * power(1 + rate / 1200, tenure)
                 / (power(1 + rate / 1200, tenure) - 1), 0)::int AS emi,
           (round(inc * 0.4 * power(r_ex, 2) / 100) * 100)::int AS ex_emi,
           CASE WHEN r_miss < 0.70 THEN 0 WHEN r_miss < 0.85 THEN 1
                WHEN r_miss < 0.93 THEN 2 WHEN r_miss < 0.97 THEN 3
                ELSE 4 END AS missed
    FROM loaned l
),
scored AS (
    -- Hidden "true" default probability used ONLY to simulate outcomes.
    -- You do NOT use this in your analysis; you rediscover patterns from data.
    SELECT p.*,
           least(0.9, greatest(0.01,
               0.03
               + CASE WHEN cibil IS NULL THEN 0.06 WHEN cibil < 650 THEN 0.14
                      WHEN cibil < 700 THEN 0.06 WHEN cibil < 750 THEN 0.02 ELSE 0 END
               + 0.05 * missed
               + CASE WHEN (emi + ex_emi)::numeric / inc > 0.5 THEN 0.12
                      WHEN (emi + ex_emi)::numeric / inc > 0.4 THEN 0.06 ELSE 0 END
               + CASE loan_type WHEN 'Personal Loan' THEN 0.05
                                WHEN 'Two-Wheeler Loan' THEN 0.03
                                WHEN 'Gold Loan' THEN 0.02
                                WHEN 'Home Loan' THEN -0.02 ELSE 0 END
               + CASE employment_type WHEN 'Self-Employed' THEN 0.03
                                      WHEN 'Business Owner' THEN 0.02
                                      WHEN 'Salaried - Govt/PSU' THEN -0.015 ELSE 0 END
           )) AS prob
    FROM priced p
)
SELECT age, city, employment_type, inc, cibil, loan_type, amt, tenure, rate,
       emi, ex_emi, missed, (r_def < prob)::int
FROM scored;

-- Make the data messy, like real life (gives you cleaning stories):
-- 1) duplicate applications (same details, new loan_id)
INSERT INTO loans_raw
    (age, city, employment_type, monthly_income_inr, cibil_score, loan_type,
     loan_amount_inr, tenure_months, interest_rate_pct, emi_inr,
     existing_emi_inr, missed_payments_12m, defaulted)
SELECT age, city, employment_type, monthly_income_inr, cibil_score, loan_type,
       loan_amount_inr, tenure_months, interest_rate_pct, emi_inr,
       existing_emi_inr, missed_payments_12m, defaulted
FROM loans_raw ORDER BY random() LIMIT 150;

-- 2) impossible ages (data entry errors)
UPDATE loans_raw SET age = CASE WHEN random() < 0.5 THEN 0 ELSE 150 END
WHERE random() < 0.003;

-- 3) zero income (missing salary entered as 0)
UPDATE loans_raw SET monthly_income_inr = 0 WHERE random() < 0.004;

-- 4) CIBIL "-1" placeholder (credit bureaus use -1/NH for no history)
UPDATE loans_raw SET cibil_score = -1 WHERE random() < 0.01;

-- Quick check
SELECT COUNT(*) AS total_rows FROM loans_raw;
SELECT * FROM loans_raw LIMIT 10;


-- =====================================================================
-- PART 2: PROFILE THE MESS (write down what you find)
-- =====================================================================
SELECT COUNT(*)                                          AS total_rows,
       COUNT(*) FILTER (WHERE cibil_score IS NULL)       AS cibil_null,
       COUNT(*) FILTER (WHERE cibil_score = -1)          AS cibil_minus1,
       COUNT(*) FILTER (WHERE age NOT BETWEEN 21 AND 65) AS impossible_age,
       COUNT(*) FILTER (WHERE monthly_income_inr <= 0)   AS zero_income
FROM loans_raw;

-- Duplicate applications (identical on every field except loan_id)
SELECT age, city, employment_type, monthly_income_inr, cibil_score, loan_type,
       loan_amount_inr, tenure_months, interest_rate_pct, emi_inr,
       existing_emi_inr, missed_payments_12m, defaulted, COUNT(*) AS copies
FROM loans_raw
GROUP BY age, city, employment_type, monthly_income_inr, cibil_score, loan_type,
         loan_amount_inr, tenure_months, interest_rate_pct, emi_inr,
         existing_emi_inr, missed_payments_12m, defaulted
HAVING COUNT(*) > 1;


-- =====================================================================
-- PART 3: CLEAN DATA -> loans_clean
-- Decisions (be ready to justify each one):
--  * Remove exact duplicates (keep the first)
--  * Remove ages outside 21-65 (impossible / outside lending policy)
--  * Remove zero-income rows (cannot compute FOIR)
--  * Convert CIBIL -1 to NULL; treat NULL as "No history" (new-to-credit),
--    NOT as a low score, because they are a different risk group
--  * Add FOIR = (new EMI + existing EMIs) / monthly income
-- =====================================================================
CREATE TABLE loans_clean AS
WITH dedup AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY age, city, employment_type, monthly_income_inr,
                            cibil_score, loan_type, loan_amount_inr, tenure_months,
                            interest_rate_pct, emi_inr, existing_emi_inr,
                            missed_payments_12m, defaulted
               ORDER BY loan_id) AS rn
    FROM loans_raw
)
SELECT loan_id, age,
       CASE WHEN age < 30 THEN '21-29' WHEN age < 40 THEN '30-39'
            WHEN age < 50 THEN '40-49' ELSE '50+' END AS age_group,
       city, employment_type, monthly_income_inr,
       NULLIF(cibil_score, -1) AS cibil_score,
       CASE WHEN cibil_score IS NULL OR cibil_score = -1 THEN 'No history'
            WHEN cibil_score < 650 THEN 'Below 650'
            WHEN cibil_score < 700 THEN '650-699'
            WHEN cibil_score < 750 THEN '700-749'
            ELSE '750+' END AS cibil_band,
       loan_type, loan_amount_inr, tenure_months, interest_rate_pct,
       emi_inr, existing_emi_inr, missed_payments_12m,
       ROUND((emi_inr + existing_emi_inr)::numeric / monthly_income_inr, 3) AS foir,
       defaulted
FROM dedup
WHERE rn = 1 AND age BETWEEN 21 AND 65 AND monthly_income_inr > 0;

ALTER TABLE loans_clean ADD PRIMARY KEY (loan_id);

-- How many rows did cleaning remove?
SELECT (SELECT COUNT(*) FROM loans_raw)   AS raw_rows,
       (SELECT COUNT(*) FROM loans_clean) AS clean_rows;


-- =====================================================================
-- PART 4: EXPLORE (find your own top 3 findings; they drive your rules)
-- =====================================================================
-- Overall default rate
SELECT COUNT(*) AS loans, SUM(defaulted) AS defaults,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean;

-- By loan type
SELECT loan_type, COUNT(*) AS loans, SUM(defaulted) AS defaults,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean GROUP BY loan_type ORDER BY default_rate_pct DESC;

-- By CIBIL band
SELECT cibil_band, COUNT(*) AS loans,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean GROUP BY cibil_band ORDER BY default_rate_pct DESC;

-- By FOIR band (Indian banks watch this closely)
SELECT CASE WHEN foir > 0.5 THEN 'Above 50%'
            WHEN foir > 0.4 THEN '40-50%'
            ELSE 'Up to 40%' END AS foir_band,
       COUNT(*) AS loans,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean GROUP BY 1 ORDER BY default_rate_pct DESC;

-- By missed payments in last 12 months
SELECT missed_payments_12m, COUNT(*) AS loans,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean GROUP BY missed_payments_12m ORDER BY missed_payments_12m;

-- By employment type
SELECT employment_type, COUNT(*) AS loans,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loans_clean GROUP BY employment_type ORDER BY default_rate_pct DESC;

-- By city (window function + CTE): top 3 riskiest cities within each loan type
WITH city_loan AS (
    SELECT loan_type, city, COUNT(*) AS loans,
           ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
    FROM loans_clean
    GROUP BY loan_type, city
    HAVING COUNT(*) >= 50          -- ignore tiny groups
)
SELECT *
FROM (SELECT *, RANK() OVER (PARTITION BY loan_type ORDER BY default_rate_pct DESC) AS rnk
      FROM city_loan) x
WHERE rnk <= 3
ORDER BY loan_type, rnk;


-- =====================================================================
-- PART 5: BUILD THE RISK SCORE (rules live in a table, not hardcoded)
-- >>> After Part 4, CHANGE the points/thresholds based on what YOU saw. <<<
-- =====================================================================
CREATE TABLE risk_rules (
    rule_id      TEXT PRIMARY KEY,
    description  TEXT,
    points       INT
);

INSERT INTO risk_rules VALUES
('R1', 'CIBIL score below 650',                    3),
('R2', 'No credit history (new-to-credit)',        2),
('R3', 'CIBIL score 650-699',                      1),
('R4', 'FOIR above 50%',                           3),
('R5', 'FOIR between 40% and 50%',                 1),
('R6', 'One missed payment in last 12 months',     1),
('R7', 'Two or more missed payments in 12 months', 3),
('R8', 'Unsecured/high-risk product (Personal, Two-Wheeler)', 1),
('R9', 'Self-employed or business owner',          1);

-- Which loans trigger which rule
CREATE VIEW loan_rule_hits AS
SELECT loan_id, 'R1' AS rule_id FROM loans_clean WHERE cibil_score < 650
UNION ALL SELECT loan_id, 'R2' FROM loans_clean WHERE cibil_score IS NULL
UNION ALL SELECT loan_id, 'R3' FROM loans_clean WHERE cibil_score BETWEEN 650 AND 699
UNION ALL SELECT loan_id, 'R4' FROM loans_clean WHERE foir > 0.5
UNION ALL SELECT loan_id, 'R5' FROM loans_clean WHERE foir > 0.4 AND foir <= 0.5
UNION ALL SELECT loan_id, 'R6' FROM loans_clean WHERE missed_payments_12m = 1
UNION ALL SELECT loan_id, 'R7' FROM loans_clean WHERE missed_payments_12m >= 2
UNION ALL SELECT loan_id, 'R8' FROM loans_clean WHERE loan_type IN ('Personal Loan', 'Two-Wheeler Loan')
UNION ALL SELECT loan_id, 'R9' FROM loans_clean WHERE employment_type IN ('Self-Employed', 'Business Owner');

-- Total points per loan (join rules + lookup table)
CREATE VIEW loan_scores AS
SELECT c.loan_id, COALESCE(SUM(r.points), 0) AS risk_points
FROM loans_clean c
LEFT JOIN loan_rule_hits h ON h.loan_id = c.loan_id
LEFT JOIN risk_rules r     ON r.rule_id = h.rule_id
GROUP BY c.loan_id;

-- Bucket: Low (0-2), Medium (3-5), High (6+)
CREATE VIEW loan_risk_buckets AS
SELECT c.*, s.risk_points,
       CASE WHEN s.risk_points >= 6 THEN 'High'
            WHEN s.risk_points >= 3 THEN 'Medium'
            ELSE 'Low' END AS risk_bucket
FROM loans_clean c
JOIN loan_scores s USING (loan_id);


-- =====================================================================
-- PART 6: VALIDATE THE SCORE (your headline result)
-- Default rate should rise from Low -> Medium -> High
-- =====================================================================
SELECT risk_bucket,
       COUNT(*)                                   AS loans,
       SUM(defaulted)                             AS defaults,
       ROUND(100.0 * SUM(defaulted) / COUNT(*), 1) AS default_rate_pct,
       ROUND(100.0 * SUM(defaulted) / SUM(SUM(defaulted)) OVER (), 1) AS pct_of_all_defaults
FROM loan_risk_buckets
GROUP BY risk_bucket
ORDER BY MIN(risk_points);

-- Default rate at each points level (shows the trend more finely)
SELECT risk_points, COUNT(*) AS loans,
       ROUND(100.0 * AVG(defaulted), 1) AS default_rate_pct
FROM loan_risk_buckets GROUP BY risk_points ORDER BY risk_points;

-- Where does the score FAIL? (be honest about this in the interview)
SELECT 'High risk but did NOT default' AS case_type, COUNT(*) AS loans
FROM loan_risk_buckets WHERE risk_bucket = 'High' AND defaulted = 0
UNION ALL
SELECT 'Low risk but DID default', COUNT(*)
FROM loan_risk_buckets WHERE risk_bucket = 'Low' AND defaulted = 1;


-- =====================================================================
-- PART 7: BUSINESS OUTPUT + PERFORMANCE
-- =====================================================================
-- Watch-list of borrowers for early collections calls
CREATE VIEW high_risk_borrowers AS
SELECT loan_id, city, loan_type, loan_amount_inr, cibil_score, foir,
       missed_payments_12m, risk_points
FROM loan_risk_buckets
WHERE risk_bucket = 'High';

SELECT * FROM high_risk_borrowers ORDER BY risk_points DESC, loan_amount_inr DESC LIMIT 20;

-- Exposure (INR crore) sitting in High-risk loans, by loan type
SELECT loan_type,
       COUNT(*) AS high_risk_loans,
       ROUND(SUM(loan_amount_inr) / 10000000.0, 2) AS exposure_crore
FROM high_risk_borrowers
GROUP BY loan_type ORDER BY exposure_crore DESC;

-- Index + proof it helps (compare timings before/after)
EXPLAIN ANALYZE SELECT * FROM loans_clean WHERE loan_type = 'Personal Loan' AND city = 'Pune';
CREATE INDEX idx_loans_type_city ON loans_clean (loan_type, city);
EXPLAIN ANALYZE SELECT * FROM loans_clean WHERE loan_type = 'Personal Loan' AND city = 'Pune';


-- =====================================================================
-- PART 8: MAKE IT YOURS (do at least 2 of these)
-- =====================================================================
-- * Change setseed() to your own number
-- * Re-tune rule points/thresholds after Part 4 and note why
-- * Add a rule of your own (e.g., loan amount above 10x monthly income)
-- * Try different bucket cut-offs and compare how well they separate defaults
-- * Add a Python/Excel chart of default rate by bucket

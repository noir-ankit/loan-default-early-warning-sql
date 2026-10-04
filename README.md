# Loan Default Early-Warning Score (PostgreSQL)

A rule-based credit risk score built in SQL on 20,000 **simulated** Indian retail loan records. It flags borrowers likely to default and tests whether the score actually works.

> **Data note:** The dataset is synthetic and modelled on Indian retail lending (CIBIL score, FOIR, EMI, 90+ DPD default, INR amounts, Indian cities). It is **not** real bank data and not from ICICI or any other bank.

## Problem
Can simple, explainable rules identify borrowers who are likely to default, early enough for a bank to act?

## Tools
PostgreSQL (pgAdmin), SQL (CTEs, window functions, views, indexes), Excel (results workbook and charts)

## Dataset
- 20,000 generated loan records (plus 150 planted duplicates), 6 loan types: Personal, Home, Auto, Two-Wheeler, Education, Gold
- Fields: age, city, employment type, monthly income (INR), CIBIL score, loan amount, tenure, interest rate, EMI, existing EMIs, missed payments in last 12 months, default flag (90+ days past due)
- Deliberately messy, to practise cleaning: duplicate applications, impossible ages, zero income, CIBIL `-1` placeholders and missing CIBIL values

## Method
1. **Generate data** with `generate_series()` and `random()`, using a seed for repeatability.
2. **Profile the mess:** count nulls, impossible values and duplicates.
3. **Clean** into `loans_clean` (20,150 raw rows to 19,884 clean rows):
   - removed exact duplicates with `ROW_NUMBER()`
   - removed ages outside 21-65 and zero-income rows
   - converted CIBIL `-1` to NULL and treated it as a separate "No history" group (new-to-credit customers are unknown risk, not low score)
   - added **FOIR** (Fixed Obligation to Income Ratio) = (new EMI + existing EMIs) / monthly income
4. **Explore** default rates by CIBIL band, FOIR band, missed payments, loan type, employment type and city.
5. **Build the score:** 9 rules stored in a `risk_rules` lookup table (not hardcoded), each with points. Views total the points per loan and bucket them: Low (0-2), Medium (3-5), High (6+).
6. **Validate:** check whether the actual default rate rises across buckets.
7. **Business output:** a `high_risk_borrowers` watch-list view and exposure in INR crore by loan type.

## Results

### Risk bucket validation
| Risk bucket | Loans | Defaults | Default rate | Share of all defaults |
|---|---|---|---|---|
| Low | 6,770 | 539 | 8.0% | 15.6% |
| Medium | 9,873 | 1,898 | 19.2% | 55.0% |
| High | 3,241 | 1,016 | 31.3% | 29.4% |

The default rate rises at every step. High-risk borrowers default about **4x** as often as Low-risk borrowers. The default rate also rises almost steadily with risk points, from 3.4% at 0 points to 50.0% at 11 points.

### Top findings
1. **Missed payments:** default rate climbs from 14.2% (none missed) to 33.7% (four missed), about 2.4x.
2. **CIBIL score:** below 650 defaults at 28.5%, versus 14.3% for 750+, about 2x.
3. **FOIR:** above 50% defaults at 22.0%, versus 11.9% for up to 40%, about 1.8x.

### Exposure in High-risk loans
| Loan type | High-risk loans | Exposure (INR crore) |
|---|---|---|
| Home Loan | 840 | 248.18 |
| Personal Loan | 1,193 | 52.66 |
| Auto Loan | 458 | 38.93 |
| Education Loan | 269 | 35.27 |
| Gold Loan | 256 | 5.69 |
| Two-Wheeler Loan | 225 | 3.19 |

About INR 384 crore sits in High-risk loans, roughly 65% of it in home loans. A collections team should prioritise by exposure, not just by loan count.

## Limitations
- **Simulated data.** Real bank data is confidential. The overall default rate (~17%) and the share of loans with FOIR above 50% (~44%) are much higher than in real portfolios, so patterns are easier to see here than they would be in practice.
- **Partly circular.** Because I generated the outcomes with built-in logic, the score working is partly expected. The value of the project is the method: cleaning, rule design and validation.
- **Many false alarms.** About 69% of High-risk borrowers did not default (2,225 of 3,241), and 539 Low-risk borrowers did default.
- **Simple rules.** Points are not weighted or fitted statistically.

## Next steps
- Tune rule points and cut-offs and compare defaults caught against loans flagged
- Try logistic regression in Python and compare it with the rule-based score
- Test on a separate time period and on real data

## My changes
<!-- Fill this in with what you changed or added yourself, for example: -->
<!-- - Changed the random seed to ... -->
<!-- - Raised the FOIR threshold from 50% to 60% and compared the results -->
<!-- - Added a rule for ... -->

## Files
| File | Description |
|---|---|
| `loan_early_warning_india.sql` | Full PostgreSQL script: data generation, cleaning, scoring, validation, views |
| `loan_risk_results.xlsx` | Results workbook with summary, tables and charts |
| `README.md` | This file |

## How to run
1. Install PostgreSQL and pgAdmin, and create a database (for example `loan_risk`).
2. Open the Query Tool and load `loan_early_warning_india.sql`.
3. Run Parts 0 and 1 together first, in one session.
4. Then run the remaining parts in order, one query at a time, and read each result in the Data Output tab.
5. Do not run the whole script again unless you want to regenerate the data. Part 0 drops and rebuilds all tables.

# AMEX benchmark canonical source v1

statement_currency: USD
statement_period: 2026-01

## Transactions

| date | merchant | signed_amount_minor | page_index |
| --- | --- | ---: | ---: |
| 2026-01-03 | Lantern Cafe | 1234 | 0 |
| 2026-01-04 | Orbit Paper Co. | -500 | 0 |
| 2026-01-04 | Orbit Paper Co. | -500 | 0 |
| 2026-01-06 | Northwind Books | -999 | 0 |

## Critical Values

| id | kind | signed_amount_minor | date | currency |
| --- | --- | ---: | --- | --- |
| new_balance | amount | 12733 |  | USD |
| minimum_payment | amount | 2500 |  | USD |
| payment_due_date | date |  | 2026-02-15 |  |
| credit_limit | amount | 100000 |  | USD |
| payments_credits | amount | -5000 |  | USD |
| fees | amount | 0 |  | USD |
| interest | amount | 123 |  | USD |

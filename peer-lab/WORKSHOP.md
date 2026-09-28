# Day of Datomic Pro — Workshop

In this workshop, you will model a schema, import a banking dataset, and
work through three challenges using Datomic queries and Clojure. You choose
the attribute names, types, uniqueness constraints, cardinality, and import
strategy. There is more than one good way to get the results.

We will explore Datomic together, so try different approaches and share what
you find. If you get stuck or have trouble following along, ask for help.

We will use [datomic-lab](https://github.com/joaomello/datomic-lab), with a
Datomic Pro transactor using dev storage, a peer REPL, and Grafana dashboards.
The session builds on the Clojure and Datomic basics from Day of Datomic.

## Setup

1. Follow the [repository setup instructions](../README.md) to install the
   prerequisites. Then run these commands from the `datomic-lab` repository
   root and keep the terminal open while the lab is running:

   ```bash
   ./build.sh   # first time only
   ./start.sh
   ```

2. Open `datomic-lab/peer-lab/` in your editor of preference and start a REPL
   with the `:dev` alias (`clj -M:dev`, or your editor's jack-in using that
   alias). The [peer README](README.md) covers
   connecting and opening the peer metrics endpoint.

3. Open [src/lab/workshop.clj](src/lab/workshop.clj) and load the namespace.
   Choose an unused database name in `uri` and evaluate its `def` form. Then run the
   `d/create-database` and `d/connect` forms inside the `comment` block.
   Use this file as your scratchpad for the schema, imports, and queries.

Dashboards are in Grafana at <http://localhost:3000>:
**Datomic → Transactor Metrics** and **Datomic → Peer Metrics**.
[OBSERVABILITY.md](../OBSERVABILITY.md) explains the panels and
log queries.

The helpers in [lab.utils](src/lab/utils.clj) read the CSV files:
`read-customers`, `read-accounts`, and `read-ledger-entries`. Each returns a map
with `:header` and `:rows`; each row is a map with keyword keys and string
values. `parse-date` and `parse-decimal` can help convert those values for
your schema.

You write the code that turns rows into transaction data and submits it to
Datomic. Start with a small batch to check your schema and conversions, then
import the rest. Keep Grafana open and try different batch sizes to see how
they affect the transactor.

## Datasets

The datasets are included in [resources/workshop/](resources/workshop/).
That folder contains three CSV files and an `expected/` folder with expected
results for the challenges.

The data represents a small Brazilian retail bank. Customers have accounts
at branches, and each account has ledger entries: PIX, TED, card purchases,
fees, interest, and boleto. Card purchases include merchant details. All
amounts are in BRL.

The CSV files are UTF-8, comma-separated, with a header row. Values are
double-quoted where needed. An empty field means there is no value.

Create your schema and import the three files before starting the challenges.
The tables below describe the source data; you decide how to represent it
in Datomic.

### `customers.csv` — 10,000 rows

| Column | Type / format | Notes |
|---|---|---|
| `customer_id` | string, `C` + 6 digits (`C000123`) | Id from the source system |
| `document_number` | string, mathematically valid 11-digit CPF | |
| `full_name` | string | |
| `birth_date` | `YYYY-MM-DD` | |
| `email` | string | |
| `phone` | string, `+55` + 10–11 digits | |
| `city` | string | |
| `state` | string, 2-letter UF (`SP`, `RJ`) | |
| `segment` | string, one of `retail`, `premium`, `private` | |
| `risk_score` | integer 0–1000 | |
| `created_at` | ISO-8601 UTC (`2023-04-12T14:03:22Z`) | |

### `accounts.csv` — 20,000 rows

| Column | Type / format | Notes |
|---|---|---|
| `account_id` | string, `A` + 6 digits | Id from the source system |
| `customer_id` | string | References `customers.csv` |
| `branch_code` | string, 4 digits (`0001`–`0050`) | |
| `account_number` | string, 6 digits + `-` + check digit (`123456-7`; check digit = sum of the six digits mod 10) | Unique within a branch |
| `account_type` | string, one of `checking`, `savings`, `salary` | |
| `status` | string, one of `active`, `blocked`, `closed` | |
| `opened_at` | `YYYY-MM-DD` | |
| `closed_at` | `YYYY-MM-DD` or empty | Empty unless `status = closed` |
| `overdraft_limit` | decimal string, 2 places (`1500.00`) | May be `0.00` |

Each customer has between 1 and 4 accounts.

### `ledger_entries.csv` — 300,000 rows

| Column | Type / format | Notes |
|---|---|---|
| `entry_id` | string, `E` + 9 digits | Unique in the file |
| `account_id` | string | References `accounts.csv` |
| `posted_at` | ISO-8601 UTC | When the entry hit the account |
| `amount` | decimal string, 2 places, always positive | Sign is carried by `direction` |
| `direction` | string, `debit` or `credit` | |
| `entry_type` | string, one of `pix`, `ted`, `card`, `fee`, `interest`, `boleto` | |
| `merchant_id` | string, `M` + 5 digits, or empty | Only for `card`; ~5,000 distinct |
| `merchant_name` | string or empty | Same `merchant_id` always has the same name |
| `mcc_code` | string, 4 digits, or empty | Merchant category code |
| `description` | string | Free text, up to ~80 chars |
| `balance_after` | decimal string, 2 places, signed | Account balance after this entry |

## Challenges

Use the full dataset for all three challenges. You can combine Datomic
queries and Clojure as needed. Each challenge includes a link to the expected
results for reference.

### 1. Statement

Build a March 2024 statement for the account with `branch_code = "0007"`
and `account_number = "482913-7"`. Include entries from
`2024-03-01T00:00:00Z` up to, but excluding, `2024-04-01T00:00:00Z`.
Return `[posted_at entry_type direction amount description balance_after]`, ordered
by `posted_at` ascending; break equal timestamps by `entry_id` ascending.

Expected results: [c1.edn](resources/workshop/expected/c1.edn).

### 2. Balance per customer

Calculate each customer's total balance across all their accounts. Match
customers to accounts using `customer_id`. An account's balance is the
`balance_after` from its most recent entry by `posted_at`; if it has no
entries, use `0.00`. If the latest timestamps tie, use the entry with the
greatest `entry_id` (the last entry in statement order).

Sum the account balances and return one row for every customer in
`customers.csv`, ordered by `customer_id` ascending:
`[customer_id document_number full_name total_balance]`.

Expected results: [c2.edn](resources/workshop/expected/c2.edn).

### 3. Where premium customers spend

Find the 10 merchants where premium customers spent the most on card
purchases. Include entries with `entry_type = "card"` and
`direction = "debit"` from accounts belonging to customers with
`segment = "premium"`.

Group by merchant (`merchant_id`, `merchant_name`) and sum `amount`.
Return `[merchant_id merchant_name total_amount]`, ordered by total spending
from highest to lowest, breaking ties by `merchant_id` and then `merchant_name`
ascending, keeping only the top 10.

Expected results: [c3.edn](resources/workshop/expected/c3.edn).

(ns lab.workshop
  (:require [datomic.api :as d]
            [lab.utils :as utils]))


(def uri "datomic:dev://localhost:4334/conj-workshop")

(require 'lab.datomic-metrics)
(lab.datomic-metrics/start!)
(slurp "http://localhost:9101/metrics")


(comment
  (d/create-database uri)
  (def con (d/connect uri))

  ;; helper functions
  (lab.utils/parse-date "2020-09-14T18:14:24Z")
  (lab.utils/parse-date "2021-11-09")
  (lab.utils/parse-decimal "6300.00")


  ;; instructions at WORSHOP.md
  
  ;; accounts.csv
  (doseq [{:keys [account_id customer_id branch_code account_number account_type
                  status opened_at closed_at overdraft_limit]}
          (:rows (utils/read-accounts))]
    )

  ;; customers.csv
  (doseq [{:keys [customer_id document_number full_name birth_date email phone
                  city state segment risk_score created_at]}
          (:rows (utils/read-customers))]
    )

  ;; ledger_entries.csv
  (doseq [{:keys [entry_id account_id posted_at amount direction entry_type
                  merchant_id merchant_name mcc_code description balance_after]}
          (:rows (utils/ledger-entries))]
    )
  
  )

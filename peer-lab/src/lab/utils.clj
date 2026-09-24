(ns lab.utils
  (:require [clojure.data.csv :as csv]
            [clojure.java.io :as io]
            [clojure.string]))

(defn read-csv
  "Read a CSV into {:header [...]
                    :rows [{:column value ...} ...]}."
  [path]
  (with-open [r (io/reader path)]
    (let [[header & rows] (doall (csv/read-csv r))
          keys (mapv keyword header)]
      {:header header
       :rows (mapv #(zipmap keys %) rows)})))

(defn read-accounts []
  (read-csv (io/resource "workshop/accounts.csv")))

(defn read-customers []
  (read-csv (io/resource "workshop/customers.csv")))

(defn ledger-entries []
  (read-csv (io/resource "workshop/ledger_entries.csv")))

(defn parse-date
  "Parse an ISO timestamp (\"2020-09-14T18:14:24Z\") or a plain date
   (\"2021-11-09\", taken as UTC midnight) into a java.util.Date.
   Returns nil for blank input (e.g. an empty closed_at)."
  [s]
  (when-not (clojure.string/blank? s)
    (java.util.Date/from
     (if (clojure.string/includes? s "T")
       (java.time.Instant/parse s)
       (-> (java.time.LocalDate/parse s)
           (.atStartOfDay java.time.ZoneOffset/UTC)
           .toInstant)))))

(defn parse-decimal
  "Parse a decimal string (\"6300.00\") into a BigDecimal, nil if blank."
  [s]
  (when-not (clojure.string/blank? s)
    (bigdec s)))

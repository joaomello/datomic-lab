(ns lab.utils
  (:require [clojure.data.csv :as csv]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.math RoundingMode]
           [java.time Instant LocalDate ZoneOffset]
           [java.util Date]))

(defn read-csv
  "Read a CSV into {:header [...]
                    :rows [{:column value ...} ...]}."
  [path]
  (with-open [r (io/reader path)]
    (let [[header & rows] (csv/read-csv r)
          columns (mapv keyword header)]
      {:header header
       :rows (mapv #(zipmap columns %) rows)})))

(defn read-accounts []
  (read-csv (io/resource "workshop/accounts.csv")))

(defn read-customers []
  (read-csv (io/resource "workshop/customers.csv")))

(defn read-ledger-entries []
  (read-csv (io/resource "workshop/ledger_entries.csv")))

(defn parse-date
  "Parse an ISO timestamp (\"2020-09-14T18:14:24Z\") or a plain date
   (\"2021-11-09\", taken as UTC midnight) into a java.util.Date.
   Returns nil for blank input (e.g. an empty closed_at)."
  [s]
  (when-not (str/blank? s)
    (Date/from (if (str/includes? s "T")
                 (Instant/parse s)
                 (-> (LocalDate/parse s) (.atStartOfDay ZoneOffset/UTC) .toInstant)))))

(defn format-amount
  "Render a bigdec back to a 2-decimal-place plain string, matching the CSV/expected format."
  [bd]
  (.toPlainString (.setScale (bigdec bd) 2 RoundingMode/HALF_UP)))

(defn inst->iso [^Date inst]
  (.toString (.toInstant inst)))

(defn read-expected [filename]
  (edn/read-string (slurp (io/resource (str "workshop/expected/" filename))
                         :encoding "UTF-8")))

(defn parse-decimal
  "Parse a decimal string (\"6300.00\") into a BigDecimal, nil if blank."
  [s]
  (when-not (str/blank? s)
    (bigdec s)))

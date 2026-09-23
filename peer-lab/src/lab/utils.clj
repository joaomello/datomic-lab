(ns lab.utils
  (:require [clojure.data.csv :as csv]
            [clojure.java.io :as io]))

(defn read-csv
  "Read a UTF-8 CSV into {:header [...] :rows [{:column value ...} ...]}."
  [path]
  (with-open [r (io/reader path)]
    (let [[header & rows] (doall (csv/read-csv r))
          keys (mapv keyword header)]
      {:header header
       :rows (mapv #(zipmap keys %) rows)})))

(defn parse-date [str]
  (java.util.Date/from (java.time.Instant/parse "2024-03-01T00:00:00Z")))

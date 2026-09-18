(ns lab.workshop
  (:require [datomic.api :as d]))


(def uri "datomic:dev://localhost:4334/mello-workshop")


(comment
  (require 'lab.datomic-metrics)
  (lab.datomic-metrics/start!)
  (slurp "http://localhost:9101/metrics")


  (d/create-database uri)
  (def con (d/connect uri))

  @(d/transact con [{:db/ident       :account/branch-code
                     :db/valueType   :db.type/string
                     :db/cardinality :db.cardinality/one}
                    {:db/ident       :account/number
                     :db/valueType   :db.type/string
                     :db/cardinality :db.cardinality/one}


                    {:db/ident       :ledger/account
                     :db/valueType   :db.type/ref
                     :db/cardinality :db.cardinality/one}
                    {:db/ident       :ledger/post-at
                     :db/valueType   :db.type/instant
                     :db/cardinality :db.cardinality/one}])

  (require '[clojure.data.csv :as csv]
           '[clojure.java.io :as io])

  (def account-file "/Users/joao.nascimento/dev/nu/joaomello/day-of-datomic-pro/datasets/accounts.csv")
  (def a (io/reader "/Users/joao.nascimento/dev/nu/joaomello/day-of-datomic-pro/datasets/accounts.csv"))
  (def l (csv/read-csv a))

  (time (doseq [{:keys [branch_code account_number]} (:rows (read-csv account-file))]
          @(d/transact con [{:account/branch-code branch_code
                             :account/number      account_number}])))

(count (:rows (read-csv account-file)))
(d/request-index con)


(time (doseq [batch (partition-all 1000 (:rows (read-csv account-file)))]
        @(d/transact con
                    (mapv (fn [{:keys [branch_code account_number]}]
                            {:account/branch-code branch_code
                             :account/number      account_number})
                          batch))))


  (defn read-csv [path]
    (with-open [r (io/reader path)]
      (let [[header & rows] (doall (csv/read-csv r))
            ks (mapv keyword header)]
        {:header header
         :rows (mapv #(zipmap ks %) rows)})))


  (seq (d/datoms (d/db con) :eavt))

  (d/db-stats (d/db con))

  (-> (d/db-stats (d/db con))
      :attrs
      :account/branch-code)

  

  (let [[header & rows] l]
    customer_id)

  
  (println l)
  
  (with-open [reader (clojure.java.io/reader "/Users/joao.nascimento/dev/nu/joaomello/day-of-datomic-pro/datasets/accounts.csv")]
    (doseq [line (line-seq reader)]))

  


  
  )

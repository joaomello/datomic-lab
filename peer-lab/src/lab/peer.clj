(ns lab.peer
  (:require [datomic.api :as d]))

(def db-uri "datomic:dev://localhost:4334/lab")

(def schema
  [{:db/ident       :item/sku
    :db/valueType   :db.type/string
    :db/cardinality :db.cardinality/one
    :db/unique      :db.unique/identity}
   {:db/ident       :item/name
    :db/valueType   :db.type/string
    :db/cardinality :db.cardinality/one}
   {:db/ident       :item/qty
    :db/valueType   :db.type/long
    :db/cardinality :db.cardinality/one}])

(comment
  ;; start metrics
  (require 'lab.datomic-metrics)
  (lab.datomic-metrics/start!)
  ;; check metrics endpoint
  (slurp "http://localhost:9101/metrics")

  ;; create and connect to the database, have fun :)
  (d/create-database db-uri)
  (def con (d/connect db-uri))

  @(d/transact con schema)

  (d/transact con [{:item/sku  "sku-1"
                    :item/name "mouse"
                    :item/qty  7}])

  (d/q '[:find ?sku ?name ?qty
         :where
         [?e :item/sku ?sku]
         [?e :item/name ?name]
         [?e :item/qty ?qty]]
       (d/db con))

  (d/pull (d/db con) '[*] [:item/sku "sku-1"])
  (d/db-stats (d/db con))
  )

(ns lab.live
  (:require [datomic.api :as d]))

(comment
  (require '[dev.nu.morse :as morse])
  (morse/launch-in-proc)
  
  (def uri "datomic:mem://amazing")
  (d/create-database uri)
  (d/delete-database uri)

  
  (morse/inspect t1)
  (morse/inspect *1)


  (def con (d/connect uri))

  ;; we want to crate n schema to transact
  ;; {:person/name "Mello"}
  ;; only using primitives
  @(d/transact con [[:db/add "new-attr" :db/ident       :person/name]
                    [:db/add "new-attr" :db/valueType   :db.type/string]
                    [:db/add "new-attr" :db/cardinality :db.cardinality/one]])
  (def t1 *1)
  (morse/inspect *2)
  (d/resolve-tempid (:db-after t1) (:tempids t1) "new-attr")

  
  ;; same using {}
  @(d/transact con [{:db/id          "new-attr"
                     :db/ident       :person/name
                     :db/valueType   :db.type/string
                     :db/cardinality :db.cardinality/one}
                    [:db/add :person/name :db/doc "Person have a name"]])

  (into {} (d/entity (d/db con) :person/name))
  ;; => #:db{:id 72
  ;;         :ident :person/name,
  ;;         :valueType :db.type/string,
  ;;         :cardinality :db.cardinality/one}


  ;; we forgot to add :db/doc attribute..
  @(d/transact con [[:db/add :person/name :db/doc "Person have a name"]])
  @(d/transact con [{:db/id :person/name
                     :db/doc "Person have a name"}])
  @(d/transact con [[:db/add [:db/ident :person/name] :db/doc "Person have a name"]])
  @(d/transact con [{:db/ident :person/name
                     :db/doc "Person have a name"}])
   
 

  ;; BTW we don't need, our attributes a are so good naming, so we don't need :docs
  @(d/transact con [[:db/retract :person/name :db/doc]])
  (d/entid (d/db con) :person/name)
  ;; => 73
  @(d/transact con [[:db/retract 73           :db/doc]])
  @(d/transact con [[:db/retract [:db/ident :person/name] :db/doc]])
 
  ;; transact the first person
  @(d/transact con [{:person/name "M"}])
   
  ;; it's bad people with less than 3 words
  (defn valid-name? [a]
    (<= 3 (count a)))
   

  (valid-name? "M")


  @(d/transact con [{:db/ident      :person/name
                     :db.attr/preds 'lab.live/valid-name?}])
   

  @(d/transact con [{:person/name "D"}])
  @(d/transact con [{:person/name "Datom"}])
   

  @(d/transact con [[:db/retract :person/name :db.attr/preds]])

  ;; every body needs to have a code, so we could identify them
  ;; since people could have the same name
  @(d/transact con [{:db/ident        :person/code
                     :db/valueType    :db.type/string
                     :db/cardinality  :db.cardinality/one
                     :db/unique       :db.unique/identity}
                    {:db/ident        :person/valid
                     :db.entity/attrs [:person/name :person/code]}])

  @(d/transact con [{:person/name "Mello"
                     :person/code "7"
                     :db/ensure   :person/valid}])

  @(d/transact con [[:db/add "new" :person/name "Jarret"]
                    [:db/add "new" :person/code "7"]
                    [:db/add "new" :db/ensure :person/valid]])
  @(d/transact con [{:person/name "Jarret"
                     :db/ensure   :person/valid}])

  (into {} (d/entity (d/db con) :db/ensure))
  ;; => #:db{:ident :db/ensure,
  ;;         :valueType :db.type/ref,
  ;;         :cardinality :db.cardinality/many}

 

  (defn no-repeated-name?
    [db-after eid]
    (let [e (d/entity db-after eid)
          n (d/q '[:find (count ?e) .
                   :in $ ?name
                   :where [?e :person/name ?name]]
                 db-after (:person/name e))]
      (when (< (or n 0) 3)
        true)))

  @(d/transact con [{:db/ident        :person/valid
                     :db.entity/attrs [:person/code :person/name]
                     :db.entity/preds 'lab.live/no-repeated-name?}])
  
  @(d/transact con [{:person/name "Mello"
                     :person/code "2"
                     :db/ensure   :person/valid}])

  

  @(d/transact con [[:db/retractEntity [:person/code "7"]]])
  (d/with (d/db con) [[:db/retractEntity [:person/code "7"]]])
  ;; => {:db-before datomic.db.Db@5b3d5d7b,
  ;;     :db-after datomic.db.Db@e5b09b01,
  ;;     :tx-data
  ;;     [#datom[13194139534331 50 #inst "2026-09-30T14:30:40.640-00:00" 13194139534331 true]],
  ;;     :tempids {}}

  
  
  @(d/transact con [{:db/ident :create-person
                     :db/fn (d/function
                              {:lang   "clojure"
                               :params '[db-before person-name person-code]
                               :code   '(when (> (count person-code) 2)
                                          [{:person/name person-name
                                            :person/code person-code}])})}])

  @(d/transact con [[:create-person "Robert" "r9123"]])
  
  )

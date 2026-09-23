(ns lab.fun)

(defn valid-name? [a]
  (<= 3 (count a)))

(defn add-doc [db-before e doc]
  [[:db/add e :db/doc doc]])

(ns build
  (:require [clojure.tools.build.api :as b]))

(def class-dir "target/classes")
(def uber-file "target/datomic-metrics-standalone.jar")

(def basis (b/create-basis {:project "deps.edn"}))

(defn clean [_]
  (b/delete {:path "target"}))

(defn uberjar [_]
  (clean nil)
  (b/compile-clj {:basis     basis
                  :class-dir class-dir
                  :ns-compile ['lab.datomic-metrics 'lab.fun]})
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           :basis (b/create-basis {:root nil})}))

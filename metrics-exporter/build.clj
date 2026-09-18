(ns build
  (:require [clojure.tools.build.api :as b]))

(def class-dir "target/classes")
(def uber-file "target/datomic-metrics-standalone.jar")

(defn- uber-basis
  []
  (b/create-basis {:project "deps.edn"
                   :root    nil
                   :aliases []}))

(defn clean [_]
  (b/delete {:path "target"}))

(defn uberjar [_]
  (clean nil)
  (let [basis (uber-basis)]
    (b/copy-dir {:src-dirs ["src"] :target-dir class-dir})
    (b/uber {:class-dir class-dir
             :uber-file uber-file
             :basis     basis})))

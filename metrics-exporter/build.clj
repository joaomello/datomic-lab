(ns build
  (:require [clojure.tools.build.api :as b]))

(def class-dir "target/classes")
(def uber-file "target/datomic-metrics-standalone.jar")

(def basis (b/create-basis {:project "deps.edn"}))

(defn clean [_]
  (b/delete {:path "target"}))

(defn uberjar [_]
  (clean nil)
  (b/copy-dir {:src-dirs ["src"] :target-dir class-dir})
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           ;; note removing clojure from basis!
           ;; Datomic ships its own runtime; a second copy would make
           ;; classpath order decide which one loads.
           :basis (b/create-basis {:root nil})}))

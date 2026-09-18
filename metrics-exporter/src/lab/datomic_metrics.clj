(ns lab.datomic-metrics
  (:require [clojure.string :as str])
  (:import [io.prometheus.metrics.exporter.httpserver HTTPServer]
           [io.prometheus.metrics.instrumentation.jvm JvmMetrics]
           [io.prometheus.metrics.model.registry MultiCollector PrometheusRegistry]
           [io.prometheus.metrics.model.snapshots
            CounterSnapshot
            CounterSnapshot$CounterDataPointSnapshot
            GaugeSnapshot
            GaugeSnapshot$GaugeDataPointSnapshot
            Labels
            MetricMetadata
            MetricSnapshots]))

(set! *warn-on-reflection* true)

;; The whole exported state, rebuilt from each report.
;;   :gauges   name -> double. Zeroed every cycle before the new report is
;;             merged in, so a metric Datomic stops reporting reads 0 rather
;;             than latching at its last value forever.
;;   :counters name -> double. Cumulative; never rewound, never zeroed.
(defonce ^:private state (atom {:gauges {} :counters {}}))

(defn- config
  [property env default]
  (let [v (or (System/getProperty property) (System/getenv env))]
    (if (str/blank? v) default v)))

;; Prefixes every metric name. Defaults to the transactor's prefix, so a
;; transactor that sets nothing keeps the names it has always exported; a peer
;; sets -Ddatomic.metrics.prefix=datomic_peer_ and gets its own time series.
(defonce ^:private prefix
  (config "datomic.metrics.prefix" "DATOMIC_METRICS_PREFIX" "datomic_transactor_"))

;; memory-index-max, memory-index-threshold, and object-cache-max are
;; transactor.properties settings, not values Datomic reports at runtime -- so
;; start.sh reads them from the configured properties file and passes them
;; through here. This keeps a dashboard's reference lines sourced from the same
;; file that actually configures the transactor, instead of a second copy
;; someone has to remember to update by hand.
(def ^:private static-config-spec
  [["memory_index_max_mb" "datomic.metrics.memoryIndexMaxMB"
    "DATOMIC_METRICS_MEMORY_INDEX_MAX_MB"]
   ["memory_index_threshold_mb" "datomic.metrics.memoryIndexThresholdMB"
    "DATOMIC_METRICS_MEMORY_INDEX_THRESHOLD_MB"]
   ["object_cache_max_mb" "datomic.metrics.objectCacheMaxMB"
    "DATOMIC_METRICS_OBJECT_CACHE_MAX_MB"]])

(defn- ->snake [metric-name]
  (-> (name metric-name)
      (str/replace #"([a-z0-9])([A-Z])" "$1_$2")
      (str/replace #"([A-Z]+)([A-Z][a-z])" "$1_$2")
      str/lower-case
      ;; Prometheus metric names only accept [A-Za-z0-9_:]. Datomic promises
      ;; new metric names can appear, so do not make an unknown name fatal.
      ;; PrometheusNaming/sanitizeMetricName is deliberately not used here: 1.x
      ;; accepts UTF-8 names, so it leaves a hyphen alone instead of replacing
      ;; it, and these names have to stay legacy-safe for Grafana and PromQL.
      (str/replace #"[^a-zA-Z0-9_:]" "_")))

(defn- strip-total-suffix
  [metric-name]
  (if (str/ends-with? metric-name "_total")
    (recur (subs metric-name 0 (- (count metric-name) (count "_total"))))
    metric-name))

(defn- series-names
  [base map-valued?]
  (if map-valued?
    (map #(str base %) ["_lo" "_hi" "_sum" "_count"
                        "_sum_counter" "_count_counter"
                        "_sum_counter_total" "_count_counter_total"])
    [base]))

(defn- initial-metric-names []
  (reduce (fn [names [k suffix map-valued?]]
            (let [base (str prefix suffix)]
              (reduce #(assoc-in %1 [:claimed %2] k)
                      (assoc-in names [:by-key k] base)
                      (series-names base map-valued?))))
          {:by-key {}
           :claimed (into {}
                          (map (fn [[metric-name _ _]]
                                 [(str prefix metric-name) ::static-config]))
                          static-config-spec)}
          [[:ObjectCacheCount "object_cache_count" false]
           [:ObjectCache "object_cache_2" true]]))

(defonce ^:private metric-names (atom (initial-metric-names)))
(defonce ^:private metric-names-lock (Object.))

(defn- metric-base [k map-valued?]
  (locking metric-names-lock
    (or (get-in @metric-names [:by-key k])
        (let [base (strip-total-suffix (str prefix (->snake k)))
              free? (fn [candidate]
                      (every? (fn [metric-name]
                                (let [owner (get-in @metric-names [:claimed metric-name])]
                                  (or (nil? owner) (= owner k))))
                              (series-names candidate map-valued?)))
              unique-base (loop [candidate base suffix 2]
                            (if (free? candidate)
                              candidate
                              (recur (str base "_" suffix) (inc suffix))))]
          (swap! metric-names
                 (fn [names]
                   (reduce #(assoc-in %1 [:claimed %2] k)
                           (assoc-in names [:by-key k] unique-base)
                           (series-names unique-base map-valued?))))
          unique-base))))

(defn- observe
  [k v]
  (let [base (metric-base k (map? v))]
    (if (map? v)
      (let [sum (double (:sum v))
            cnt (double (:count v))]
        {:gauges   {(str base "_lo") (double (:lo v))
                    (str base "_hi") (double (:hi v))
                    (str base "_sum") sum
                    (str base "_count") cnt}
         ;; Publish an initial zero and never decrement cumulative totals.
         :counters {(str base "_sum_counter") (max 0.0 sum)
                    (str base "_count_counter") (max 0.0 cnt)}})
      {:gauges {base (double v)}})))

(defn- merge-observation [acc obs]
  (-> acc
      (update :gauges merge (:gauges obs))
      (update :counters #(merge-with + % (:counters obs)))))

(defn- log-metric-error! [k ^Throwable t]
  (.println System/err
            (str "lab.datomic-metrics/metrics failed for " k ": " (.getMessage t))))

(defn- record-report! [m]
  (let [observed (reduce (fn [acc [k v]]
                           (try
                             (merge-observation acc (observe k v))
                             (catch Exception t
                               (log-metric-error! k t)
                               acc)))
                         {:gauges {} :counters {}}
                         (sort-by (juxt (comp map? val) key) m))]
    (swap! state
           (fn [s]
             {:gauges   (merge (update-vals (:gauges s) (constantly 0.0))
                               (:gauges observed))
              :counters (merge-with + (:counters s) (:counters observed))}))))

(defonce ^:private warned (atom #{}))

(defn- warn-once! [context ^Throwable t]
  (when-not (contains? @warned context)
    (swap! warned conj context)
    (.println System/err
              (str "lab.datomic-metrics: " context " -- " (.getMessage t)))))

(defn- gauge-snapshot ^GaugeSnapshot [metric-name value help]
  (GaugeSnapshot.
   (MetricMetadata. metric-name help nil)
   [(GaugeSnapshot$GaugeDataPointSnapshot. (double value) Labels/EMPTY nil)]))

(defn- counter-snapshot ^CounterSnapshot [metric-name value]
  (CounterSnapshot.
   ;; Prometheus appends _total when exposing a counter, so this metadata name
   ;; of ..._sum_counter is what makes the exported series ..._sum_counter_total.
   (MetricMetadata. metric-name "Datomic cumulative total across reports" nil)
   [(CounterSnapshot$CounterDataPointSnapshot. (double value) Labels/EMPTY nil 0)]))

(defn- snapshots
  ^MetricSnapshots [coll]
  (MetricSnapshots. ^java.util.Collection (vec coll)))

(defn- safe-snapshots
  [build entries]
  (keep (fn [[metric-name v]]
          (try
            (build metric-name v)
            (catch Exception t
              (warn-once! (str "dropping " metric-name) t)
              nil)))
        entries))

(defn- datomic-collector
  ^MultiCollector []
  (reify MultiCollector
    (collect [_]
      (let [s @state]
        (snapshots
         (concat
          (safe-snapshots #(gauge-snapshot %1 %2 "Datomic metric, last reporting interval")
                          (:gauges s))
          (safe-snapshots counter-snapshot (:counters s))))))))

(defn- static-config-readings
  []
  (into {}
        (keep (fn [[metric-name property env]]
                (when-let [v (config property env nil)]
                  [(str prefix metric-name) v])))
        static-config-spec))

(defn- static-config-collector
  ^MultiCollector []
  (reify MultiCollector
    (collect [_]
      (snapshots
       (safe-snapshots
        (fn [metric-name raw]
          (gauge-snapshot metric-name (Double/parseDouble raw)
                          "Configured transactor limit, not a runtime reading"))
        (static-config-readings))))))

(defonce ^:private server (atom nil))
(defonce ^:private registered (atom false))
(defonce ^:private init-lock (Object.))

(defn- start-http! ^HTTPServer []
  (let [port (Integer/parseInt (config "datomic.metrics.port" "DATOMIC_METRICS_PORT" "9100"))
        srv (.. (HTTPServer/builder) (port port) buildAndStart)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable #(.close srv) "metrics-shutdown"))
    srv))

(defn- ensure-started!
  []
  (when-not @server
    (locking init-lock
      (when-not @registered
        (.. JvmMetrics builder register)
        (.register PrometheusRegistry/defaultRegistry (datomic-collector))
        (.register PrometheusRegistry/defaultRegistry (static-config-collector))
        (reset! registered true))
      (when-not @server
        (reset! server (start-http!))))))

(defn start!
  []
  (ensure-started!)
  nil)

(defn metrics
  [m]
  (try
    (ensure-started!)
    (catch Exception t
      (warn-once! "metrics endpoint unavailable" t)))
  (record-report! m))

(comment
  (record-report! {:AvailableMB      921.0
                   :ObjectCacheCount 464
                   :ObjectCache      {:lo 0 :hi 1 :sum 37 :count 64}
                   :HeartbeatMsec    {:lo 5000 :hi 5001 :sum 55009 :count 11}})

  (:by-key @metric-names)
  @state

  ;; Serve it: http://localhost:9100/metrics
  (start!)
  )

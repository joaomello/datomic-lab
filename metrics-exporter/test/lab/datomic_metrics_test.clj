(ns lab.datomic-metrics-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [lab.datomic-metrics])
  (:import [io.prometheus.metrics.expositionformats PrometheusTextFormatWriter]
           [io.prometheus.metrics.model.registry PrometheusRegistry]))

(defn- private-value [symbol]
  (var-get (ns-resolve 'lab.datomic-metrics symbol)))

(defn- invoke-private [symbol & args]
  (apply (private-value symbol) args))

(defn- reset-exporter! []
  (reset! (private-value 'state) {:gauges {} :counters {}})
  (reset! (private-value 'metric-names) (invoke-private 'initial-metric-names))
  (reset! (private-value 'warned) #{}))

(use-fixtures :each
  (fn [f]
    (let [saved (into {} (map (fn [k] [k @(private-value k)]))
                      '[state metric-names warned])]
      (try
        (reset-exporter!)
        (f)
        (finally
          (doseq [[k value] saved]
            (reset! (private-value k) value)))))))

(defn- state []
  @(private-value 'state))

(defn- gauge-value [base suffix]
  (get-in (state) [:gauges (str base suffix)]))

(defn- scrape
  "Return exposition text for the exporter's collectors."
  []
  (let [registry (PrometheusRegistry.)
        out (java.io.ByteArrayOutputStream.)]
    (.register registry (invoke-private 'datomic-collector))
    (.register registry (invoke-private 'static-config-collector))
    (.write (PrometheusTextFormatWriter. false) out (.scrape registry))
    (String. (.toByteArray out))))

(deftest cache-names-do-not-depend-on-report-order
  (let [cache {:ObjectCache {:lo 0 :hi 1 :sum 37 :count 64}}
        count-report {:ObjectCacheCount 466}
        prefix (private-value 'prefix)]
    (doseq [reports [[cache count-report]
                     [count-report cache]
                     [(merge cache count-report)]]]
      (testing (str "reports: " reports)
        (reset-exporter!)
        (doseq [report reports]
          (invoke-private 'record-report! report))
        (is (= (str prefix "object_cache_count")
               (invoke-private 'metric-base :ObjectCacheCount false)))
        (is (= (str prefix "object_cache_2")
               (invoke-private 'metric-base :ObjectCache true)))
        (invoke-private 'record-report! (merge cache count-report))
        (let [text (scrape)]
          (is (str/includes? text (str prefix "object_cache_count 466.0")))
          (is (str/includes? text (str prefix "object_cache_2_count 64.0")))
          (is (str/includes? text (str prefix "object_cache_2_sum_counter_total 74.0"))))))))

(deftest counters-start-at-zero-and-retain-totals
  (let [base (str (private-value 'prefix) "transaction_msec")]
    (doseq [[report expected]
            [[{:TransactionMsec {:lo 0 :hi 0 :sum 0 :count 0}} [0.0 0.0]]
             [{:TransactionMsec {:lo 1 :hi 2 :sum 3 :count 2}} [3.0 2.0]]
             [{:TransactionMsec {:lo 0 :hi 0 :sum 0 :count 0}} [3.0 2.0]]
             [{:TransactionMsec {:lo -2 :hi -1 :sum -3 :count -2}} [3.0 2.0]]
             [{} [3.0 2.0]]]]
      (invoke-private 'record-report! report)
      (let [text (scrape)]
        (doseq [[suffix value] (map vector ["_sum_counter" "_count_counter"] expected)]
          (is (= value (get-in (state) [:counters (str base suffix)])))
          (is (str/includes? text (str base suffix "_total " value))))))))

(deftest unknown-names-are-prometheus-safe-and-distinct
  (let [hyphenated :Review-Latency
        underscored :Review_Latency
        hyphenated-base (invoke-private 'metric-base hyphenated false)
        underscored-base (invoke-private 'metric-base underscored false)]
    (testing "unexpected characters are made Prometheus-safe"
      (is (re-matches #"[a-zA-Z_:][a-zA-Z0-9_:]*" hyphenated-base)))
    (testing "normalization collisions retain separate time series"
      (is (not= hyphenated-base underscored-base)))))

(deftest invalid-metric-does-not-block-other-report-values
  (let [invalid-key :Review-Invalid
        valid-key :ReviewAvailableMB
        valid-base (invoke-private 'metric-base valid-key false)]
    (invoke-private 'record-report! {invalid-key (Object.)
                                     valid-key 123.0})
    (is (= 123.0 (gauge-value valid-base "")))))

(deftest concurrent-first-observations-claim-one-name
  (let [metric-key :ReviewConcurrent
        results (->> (repeatedly 24 #(future
                                       (try
                                         (invoke-private 'metric-base metric-key false)
                                         (catch Throwable t t))))
                     doall
                     (map deref))]
    (is (every? string? results))
    (is (= 1 (count (distinct results))))))

(deftest alarm-clears-when-datomic-stops-reporting-it
  (let [alarm-key :ReviewAlarmBackPressure
        base (invoke-private 'metric-base alarm-key true)]
    (testing "alarm series track the firing report"
      (invoke-private 'record-report! {alarm-key {:lo 1 :hi 1 :sum 6 :count 6}})
      (is (= 1.0 (gauge-value base "_hi")))
      (is (= 6.0 (gauge-value base "_sum"))))
    (testing "a later report omitting the alarm drives it back to zero"
      (invoke-private 'record-report! {:AvailableMB 900.0})
      (is (= 0.0 (gauge-value base "_hi")))
      (is (= 0.0 (gauge-value base "_sum"))))
    (testing "cumulative counters are not rewound"
      (is (= 6.0 (get-in (state) [:counters (str base "_sum_counter")]))))))

(deftest scalar-that-stops-being-reported-does-not-latch
  (let [scalar-key :ReviewLatching
        base (invoke-private 'metric-base scalar-key false)]
    (invoke-private 'record-report! {scalar-key 42.0})
    (is (= 42.0 (gauge-value base "")))
    (invoke-private 'record-report! {:AvailableMB 900.0})
    (is (= 0.0 (gauge-value base "")))))

(deftest clearing-one-alarm-leaves-sibling-alarms-alone
  (let [umbrella :ReviewAlarm
        specific :ReviewAlarmSpecific
        umbrella-base (invoke-private 'metric-base umbrella true)
        specific-base (invoke-private 'metric-base specific true)]
    (invoke-private 'record-report! {umbrella {:lo 1 :hi 1 :sum 1 :count 1}
                                     specific {:lo 1 :hi 1 :sum 1 :count 1}})
    (invoke-private 'record-report! {specific {:lo 1 :hi 1 :sum 1 :count 1}})
    (is (= 0.0 (gauge-value umbrella-base "_hi")))
    (is (= 1.0 (gauge-value specific-base "_hi")))))

(deftest scalar-and-map-keys-that-normalize-alike-keep-separate-series
  (let [scalar-key :ReviewCacheCount
        map-key :ReviewCache]
    (invoke-private 'record-report! {scalar-key 466.0
                                     map-key {:lo 0 :hi 1 :sum 37 :count 64}})
    (let [scalar-base (invoke-private 'metric-base scalar-key false)
          map-base (invoke-private 'metric-base map-key true)]
      (testing "the scalar keeps the plain name"
        (is (= 466.0 (gauge-value scalar-base ""))))
      (testing "the map is pushed to its own base rather than overwriting it"
        (is (not= scalar-base (str map-base "_count")))
        (is (= 64.0 (gauge-value map-base "_count")))
        (is (= 37.0 (gauge-value map-base "_sum")))))))

(deftest exposed-series-keep-the-names-and-types-dashboards-query
  (let [map-key :ReviewExpositionMsec
        scalar-key :ReviewExpositionAvailableMB
        map-base (invoke-private 'metric-base map-key true)
        scalar-base (invoke-private 'metric-base scalar-key false)]
    (invoke-private 'record-report! {map-key {:lo 5000 :hi 5001 :sum 55009 :count 11}
                                     scalar-key 921.0})
    (let [text (scrape)
          has? (fn [line] (str/includes? text line))]
      (testing "scalars stay plain gauges"
        (is (has? (str "# TYPE " scalar-base " gauge")))
        (is (has? (str scalar-base " 921.0"))))
      (testing "all four interval statistics are gauges under the old names"
        (doseq [[suffix value] [["_lo" "5000.0"] ["_hi" "5001.0"]
                                ["_sum" "55009.0"] ["_count" "11.0"]]]
          (is (has? (str "# TYPE " map-base suffix " gauge")) suffix)
          (is (has? (str map-base suffix " " value)) suffix)))
      (testing "no summary type is published for a resetting metric"
        (is (not (has? (str "# TYPE " map-base " summary")))))
      (testing "cumulative counters keep the _counter_total names"
        (is (has? (str "# TYPE " map-base "_sum_counter_total counter")))
        (is (has? (str map-base "_sum_counter_total 55009.0")))
        (is (has? (str map-base "_count_counter_total 11.0")))))))

(deftest static-config-is-not-zeroed-by-later-reports
  (System/setProperty "datomic.metrics.memoryIndexMaxMB" "512.0")
  (try
    (invoke-private 'record-report! {:AvailableMB 900.0})
    (is (str/includes? (scrape) (str (private-value 'prefix) "memory_index_max_mb 512.0")))
    (finally
      (System/clearProperty "datomic.metrics.memoryIndexMaxMB"))))

(deftest key-ending-in-total-does-not-break-the-endpoint
  (let [total-key :ReviewBytesTotal
        base (invoke-private 'metric-base total-key false)]
    (is (not (str/ends-with? base "_total")))
    (invoke-private 'record-report! {total-key 5.0})
    (is (str/includes? (scrape) (str base " 5.0")))))

(deftest blank-static-config-is-treated-as-unset
  (System/setProperty "datomic.metrics.objectCacheMaxMB" "")
  (try
    (is (not (contains? (invoke-private 'static-config-readings)
                        (str (private-value 'prefix) "object_cache_max_mb"))))
    (is (not (str/includes? (scrape)
                            (str (private-value 'prefix) "object_cache_max_mb"))))
    (finally
      (System/clearProperty "datomic.metrics.objectCacheMaxMB"))))

(deftest unparseable-static-config-costs-only-its-own-series
  (System/setProperty "datomic.metrics.objectCacheMaxMB" "not-a-number")
  (try
    (invoke-private 'record-report! {:AvailableMB 900.0})
    (let [text (scrape)]
      (is (not (str/includes? text (str (private-value 'prefix) "object_cache_max_mb"))))
      (is (str/includes? text (str (private-value 'prefix) "available_mb"))))
    (finally
      (System/clearProperty "datomic.metrics.objectCacheMaxMB"))))

(deftest counter-metadata-names-are-claimed-against-collision
  (let [map-key :ReviewCollideMsec
        scalar-key :ReviewCollideMsecSumCounter]
    (invoke-private 'record-report! {map-key {:lo 1 :hi 2 :sum 3 :count 4}
                                     scalar-key 9.0})
    (let [map-base (invoke-private 'metric-base map-key true)
          scalar-base (invoke-private 'metric-base scalar-key false)
          text (scrape)]
      (is (not= (str map-base "_sum_counter") scalar-base))
      (testing "a scrape still succeeds and both keys are published"
        (is (str/includes? text (str scalar-base " 9.0")))
        (is (str/includes? text (str map-base "_sum 3.0")))))))

(deftest datomic-key-cannot-collide-with-a-static-config-name
  (let [clashing-key :MemoryIndexMaxMB
        base (invoke-private 'metric-base clashing-key false)]
    (is (not= base (str (private-value 'prefix) "memory_index_max_mb")))
    (System/setProperty "datomic.metrics.memoryIndexMaxMB" "512.0")
    (try
      (invoke-private 'record-report! {clashing-key 7.0})
      (let [text (scrape)]
        (is (str/includes? text (str base " 7.0")))
        (is (str/includes? text (str (private-value 'prefix) "memory_index_max_mb 512.0"))))
      (finally
        (System/clearProperty "datomic.metrics.memoryIndexMaxMB")))))

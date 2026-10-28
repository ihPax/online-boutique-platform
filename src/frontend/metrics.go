// Platform challenge addition: Prometheus metrics for the frontend.
//
// Metrics are served on a dedicated port (METRICS_PORT, default 9090) so that
// /metrics is never reachable through the public Ingress, which only routes to
// the HTTP port 8080.

package main

import (
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gorilla/mux"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sirupsen/logrus"
)

var (
	metricsRegistry = prometheus.NewRegistry()

	httpRequestsTotal = promauto.With(metricsRegistry).NewCounterVec(
		prometheus.CounterOpts{
			Name: "frontend_http_requests_total",
			Help: "HTTP requests served by the frontend, by route template, method and status code.",
		},
		[]string{"route", "method", "code"},
	)

	httpRequestDuration = promauto.With(metricsRegistry).NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "frontend_http_request_duration_seconds",
			Help:    "Latency of HTTP requests served by the frontend, by route template and method.",
			Buckets: []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		},
		[]string{"route", "method"},
	)

	cartAdditionsTotal = promauto.With(metricsRegistry).NewCounter(prometheus.CounterOpts{
		Name: "frontend_cart_additions_total",
		Help: "Products successfully added to a cart.",
	})

	ordersPlacedTotal = promauto.With(metricsRegistry).NewCounter(prometheus.CounterOpts{
		Name: "frontend_orders_placed_total",
		Help: "Orders successfully placed through checkoutservice.",
	})

	ordersFailedTotal = promauto.With(metricsRegistry).NewCounter(prometheus.CounterOpts{
		Name: "frontend_orders_failed_total",
		Help: "Orders that failed when calling checkoutservice.",
	})
)

func init() {
	metricsRegistry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
}

// statusRecorder captures the status code written by the wrapped handler.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// metricsMiddleware is registered with router.Use, so it runs after route
// matching and can label by route template ("/product/{id}") instead of the
// raw path, which keeps label cardinality bounded.
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		route := "unmatched"
		if cr := mux.CurrentRoute(r); cr != nil {
			if tpl, err := cr.GetPathTemplate(); err == nil {
				route = tpl
			}
		}
		if route == baseUrl+"/_healthz" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		httpRequestDuration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())
		httpRequestsTotal.WithLabelValues(route, r.Method, strconv.Itoa(rec.status)).Inc()
	})
}

// startMetricsServer serves /metrics on METRICS_PORT (default 9090).
// Setting METRICS_PORT=0 disables the listener.
func startMetricsServer(log logrus.FieldLogger) {
	port := os.Getenv("METRICS_PORT")
	if port == "" {
		port = "9090"
	}
	if port == "0" {
		log.Info("metrics server disabled")
		return
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(metricsRegistry, promhttp.HandlerOpts{}))
	go func() {
		log.Infof("starting metrics server on :%s", port)
		if err := http.ListenAndServe(":"+port, mux); err != nil {
			log.WithError(err).Error("metrics server stopped")
		}
	}()
}

// logLevelFromEnv lets each environment choose its verbosity (LOG_LEVEL).
// Upstream hard-codes debug; that stays the default.
func logLevelFromEnv() logrus.Level {
	if lvl, err := logrus.ParseLevel(os.Getenv("LOG_LEVEL")); err == nil {
		return lvl
	}
	return logrus.DebugLevel
}

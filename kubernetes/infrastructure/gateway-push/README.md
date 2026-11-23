# Monitoring push endpoints (prometheus / loki remote write) — P12 A3

INVARIANT: the gateway can reach Prometheus' and Loki's write handlers for
prometheus.sharmamohit.com / loki.sharmamohit.com ONLY through the auth proxy.
It holds by construction, not by ordering:

1. The push HTTPRoutes' only backendRef is `monitoring/push-auth-proxy`. That
   proxy (upstream nginx) answers 401 unless `auth_basic` succeeds, and only
   then proxy_passes to the backend. There is no separately attachable
   SecurityPolicy whose absence or lag would open the path.
   Missing proxy Service -> Envoy direct 500; no ready pods -> 503; missing
   ReferenceGrant -> route ResolvedRefs=False -> 500. None forwards.
2. The push hostnames have exact-hostname listeners (https-prometheus,
   https-loki) that accept routes only from envoy-gateway-system. With
   SNI prometheus/loki, Envoy selects only that listener's routes.
3. The ReferenceGrant lets envoy-gateway-system HTTPRoutes reference exactly
   one Service, push-auth-proxy, by name. Prometheus and Loki are not
   referenceable from the gateway namespace.

Bring-up order (Flux): infra-gateway-push-auth (proxy, wait: health) ->
infra-gateway-push (ReferenceGrant + routes; dependsOn the former).
Teardown order: remove routes/ (infra-gateway-push) first, observe the push
hosts answer 404 at the gateway, then remove auth/. Either order is still
fail-closed by (1); the order only avoids a window of 500/503.

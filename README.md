# triton-prometheus

A repo with tooling to setup Prometheus and Grafana in a TritonDC for metrics
and monitoring of Triton itself. The goal is to make it easy (and somewhat
standardized, to simplify collaboration) to work with and monitor TritonDC
metrics.

## Status

For now this just houses lowly bash scripts for setting up prometheus0
and grafana0 zones on a Triton headnode. Eventually this might turn into a core
TritonDC "prometheus" and "grafana" services.

## How to deploy development Prometheus and Grafana for monitoring Triton

Run the following from your computer/laptop. Assuming you have something like
this in your "~/.ssh/config":

	Host coal
		User root
		Hostname 10.99.99.7
		StrictHostKeyChecking no
		UserKnownHostsFile /dev/null

Run this:

    ./setup-prometheus.sh coal      # create a prometheus0 zone
    ./setup-grafana.sh coal         # create a grafana0 zone

Then wait about 5 minutes for metrics to start coming in (I don't know what
the exact delay is) and visit the grafana URL (it is printed at the end of
`setup-grafana.sh ...`).


## Configuration

Primarily this VM runs a Prometheus server (as the "prometheus" SMF service).
The config files for that service are as follows. Note that "/data/..." is a
delegate dataset to persist through reprovisions.

    /data/prometheus/etc/prometheus.yml
    /data/prometheus/keys/*             # data with which to auth to CMON

Like most Triton core VM services, a config-agent is used to gather some
config data. Unlike many Triton core services, this VM uses an additional
config processing step to create the final prometheus config. At the
time of writing this is to allow handling an optional "cmon_domain" config var
for which the fallback default requires some processing (querying CNS for
the appropriate DNS zone). The basic process is:

1. config-agent runs to fill out "/data/prometheus/etc/sapi-inst-data.json"
2. The config-agent `post_cmd` runs
   `/opt/triton/prometheus/bin/prometheus-configure` to create the final
   `/data/prometheus/etc/prometheus.yml` and enable/restart/clear prometheus,
   if changed. In addition, on *reprovision*, "sapi-inst-data.json" might
   already exist because it is on a delegate dataset. Therefore, "boot/setup.sh"
   will also call `prometheus-configure`.


## SAPI Configuration

There are some Triton Prometheus service configuration options that can be
set in SAPI.

| Key                              | Type   | Description |
| -------------------------------- | ------ | ----------- |
| **cmon\_domain**                 | String | Optional. The domain at which Prometheus should talk to this DC's CMON, e.g. "cmon.us-east-1.triton.zone". The actual endpoint is assumed to be https and port 9163. See notes below. |
| **cmon\_insecure\_skip\_verify** | Bool   | Optional. If `cmon_domain` is provided, this can be set to `true` to have Prometheus ignore TLS cert errors from a self-signed cert. |

Prometheus gets its metrics from the DC's local CMON, typically over the
external network. To auth with CMON properly in a production environment, it
needs to know the appropriate CMON URL advertized to public DNS and for which
it has a signed TLS certificate. This is what `cmon_domain` is for. If this is
not specified, then this image will attempt to infer an appropriate URL
via querying the DC's local CNS. See `bin/prometheus-configure` for details.


An example setting these values:

    promSvc=$(sdc-sapi /services?name=prometheus | json -Ha uuid)
    sdc-sapi /services/$promSvc -X PUT \
        -d '{"metadata": {"cmon_domain": "mycmon.example.com", "cmon_insecure_skip_verify": true}}'


## Auth, Security

A Triton prometheus VM instance will create a key pair and a client certificate
using that XXX

XXX

+                // Prometheus needs to be on the external to properly work with
+                // CMON's Triton service discovery and CNS -- at least until CNS
+                // support split horizon DNS to provide separate records on the
+                // admin network. This is because CMON's Triton service
+                // discovery returns the CNS domain names for Triton's core
+                // VMs. (TODO: do I have that right?)
+                //
+                // Triton's Prometheus instances will therefore have a NIC on
+                // CMON's non-admin network. Currently by default that is the
+                // "external" network.
+                //
+                // A firewall will be setup on prometheus0 so that by default no
+                // inbound requests are allowed on that interface.

firewall_enabled=true


## Troubleshooting

### Prometheus doesn't have Triton data

Triton's Prometheus gets its data from CMON. Here are some things to check
if this appears to be failing:

- TODO: a prom query to use as the canonical check that it can talk to CMON

- Does the Prometheus config (/data/prometheus/etc/prometheus.yml) look correct?

- Is Prometheus running? `svcs prometheus`

- Does the Prometheus log show errors? E.g. (newlines added for readability):

    ```
    $ tail `svcs -L prometheus`
    ...
    level=error ts=2018-09-28T18:42:33.715136969Z caller=triton.go:170
        component="discovery manager scrape"
        discovery=trition
        msg="Refreshing targets failed"
        err="an error occurred when requesting targets from the discovery endpoint.
            Get https://mycmon.example.com:9163/v1/discover: dial tcp:
            lookup mycmon.example.com on 8.8.8.8:53: no such host"
    ```

- Is Prometheus' Triton service discovery failing? The `promtool debug metrics SERVER`
  output includes Prometheus' own service discovery attempts.

    ```
    [root@edbece93-e2da-4ce5-84d6-3e9f5d12131c (coal:prometheus0) ~]# promtool debug metrics http://localhost:9090 | grep prometheus_sd_triton
    # HELP prometheus_sd_triton_refresh_duration_seconds The duration of a Triton-SD refresh in seconds.
    # TYPE prometheus_sd_triton_refresh_duration_seconds summary
    prometheus_sd_triton_refresh_duration_seconds{quantile="0.5"} 0.005636197
    prometheus_sd_triton_refresh_duration_seconds{quantile="0.9"} 0.010158026
    prometheus_sd_triton_refresh_duration_seconds{quantile="0.99"} 0.010158026
    prometheus_sd_triton_refresh_duration_seconds_sum 0.077228126
    prometheus_sd_triton_refresh_duration_seconds_count 4
    # HELP prometheus_sd_triton_refresh_failures_total The number of Triton-SD scrape failures.
    # TYPE prometheus_sd_triton_refresh_failures_total counter
    prometheus_sd_triton_refresh_failures_total 0
    ```

    Specifically are there any `prometheus_sd_triton_refresh_failures_total`?

    One reason for failures might be that the Prometheus public key
    (at "/data/prometheus/etc/prometheus.id_rsa.pub") has not been added to
    the admin user. See `sdc-useradm keys admin`.

- Are CMON scrapes working?

    ```
    $ promtool debug metrics http://localhost:9090 | grep prometheus_target_sync_length_seconds_count
    prometheus_target_sync_length_seconds_count{scrape_job="admin_coal"} 7
    ```

    TODO: I'm not sure this can show if current scrapes are working. Improve
    this. Perhaps these?

    ```
    # HELP promhttp_metric_handler_requests_total Total number of scrapes by HTTP status code.
    # TYPE promhttp_metric_handler_requests_total counter
    promhttp_metric_handler_requests_total{code="200"} 11
    promhttp_metric_handler_requests_total{code="500"} 0
    promhttp_metric_handler_requests_total{code="503"} 0
    ```

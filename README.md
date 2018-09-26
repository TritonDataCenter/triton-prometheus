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
time of writing this is to allow handling an optional "cmon_url" config var
for which the fallback default requires some processing (querying CNS for
the appropriate DNS zone). The process is:

1. config-agent runs to fill out "/data/prometheus/etc/service-data.json"
2. The config-agent `post_cmd` runs `/opt/triton/prometheus/bin/prometheus-configure`
   to create the final `/data/prometheus/etc/prometheus.yml` and restart
   prometheus if changed.


# SAPI Configuration

There are some Triton Prometheus service configuration options that can be
set in SAPI.

| Key                              | Type   | Description |
| -------------------------------- | ------ | ----------- |
| **cmon\_url**                    | String | Optional. The base URL at which Prometheus should talk to this DC's CMON. See notes below. |
| **cmon\_insecure\_skip\_verify** | Bool   | Optional. If `cmon_url` is provided, this can be set to `true` to have Prometheus ignore TLS cert errors from a self-signed cert. |


An example setting these values:

    promSvc=$(sdc-sapi /services?name=prometheus | json -Ha uuid)
    sdc-sapi /services/$promSvc -X PUT \
        -d '{"metadata": {"cmon_url": "https://mycmon.example.com", "cmon_insecure_skip_verify": true}}'

# triton-prometheus

A repo with tooling to setup Prometheus and Grafana in a TritonDC for metrics
and monitoring of Triton itself. The goal is to make it easy (and somewhat
standardized, to simplify collaboration) to work with and monitor TritonDC
metrics.

## Status

For now this just houses lowly bash scripts for setting up prometheus0
and grafana0 zones on a Triton headnode. Eventually this might turn into a core
TritonDC "prometheus" and "grafana" services.


## How to deploy *development* Prometheus and Grafana for monitoring Triton

(Note: This method is for development and will be deprecated when core
tooling and images for prom and grafana are available.)

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


## CMON Auth

Prometheus needs to auth with the local CMON. To do this its zone setup creates
a key and appropriate client certificate in "/data/prometheus/keys/". The
created public key *must be added to the 'admin' account*. Typically this is
handled automatically by `sdcadm post-setup prometheus` (VM setup adds its
public key to its `instPubKey` metadata key, from which sdcadm grabs it).


## Security

Prometheus listens on the admin and external networks. The firewall with the
[standard Triton rules](https://github.com/joyent/sdc-headnode/blob/34dbd8acd65523c844385a81239ea0a872750326/scripts/headnode.sh#L188-L228)
is enabled to disallow incoming requests on the external network.

Prometheus is on the external network so it can access CMON and work with CNS --
at least until CNS support split horizon DNS to provide separate records on the
admin network. This is because CMON's Triton service discovery returns the CNS
domain names for Triton's core VMs.

Prometheus is on the admin network because Triton's Grafana accesses prometheus
on the admin.


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

- Is Prometheus' Triton service discovery authenticating properly to CMON? If
  not, the CMON log will show something like this:

    ```
    [2018-10-04T22:27:37.632Z]  INFO: cmon/17801 on 2539de9f-43d0-49c4-af79-4f02d53dcdde: handled: 401 (req_id=495dcfb9-054a-48fd-85b4-ed0a1500b9bc, route=getcontainers, audit=true, remoteAddress=10.128.0.10, remotePort=58600, latency=2, _audit=true, req.query="", req.version=*)
        GET /v1/discover HTTP/1.1
        host: cmon.coal.cns.joyent.us:9163
        user-agent: Go-http-client/1.1
        accept-encoding: gzip
        --
        HTTP/1.1 401 Unauthorized
        content-type: application/json
        content-length: 41
        date: Thu, 04 Oct 2018 22:28:37 GMT
        server: cmon
        x-request-id: 0a1f7159-39f7-45a6-b724-f9ec68831899
        x-response-time: 18
        x-server-name: 2539de9f-43d0-49c4-af79-4f02d53dcdde

        {
          "code": "UnauthorizedError",
          "message": ""
        }
    ```

    One reason for failures might be that the Prometheus public key
    (at "/data/prometheus/etc/prometheus.id_rsa.pub") has not been added to
    the admin user. See `sdc-useradm keys admin`.


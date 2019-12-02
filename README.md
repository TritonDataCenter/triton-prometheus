# triton-prometheus

This repository is part of the Joyent Triton and Manta projects.
For contribution guidelines, issues, and general documentation, visit the main
[Triton](http://github.com/joyent/triton) and
[Manta](http://github.com/joyent/manta) project pages.

The Triton and Manta core Prometheus service. Triton and Manta use Prometheus
and [Grafana](https://github.com/joyent/triton-grafana) to track their own
metrics and monitor themselves. All metrics are gathered via
[CMON](https://github.com/joyent/triton-cmon).

This repo builds one zone image which can be deployed as an instance of a Triton
or Manta service. The targets Prometheus scrapes will depend on whether the
instance is deployed as part of Triton or Manta.


## Active Branches

There are currently two active branches of this repository, for the two
active major versions of Manta. See the [mantav2 overview
document](https://github.com/joyent/manta/blob/master/docs/mantav2.md) for
details on major Manta versions.

- [`master`](../../tree/master/) - For development of mantav2, the latest
  version of Manta. This is the version used by Triton.
- [`mantav1`](../../tree/mantav1/) - For development of mantav1, the long
  term support maintenance version of Manta.


## Status

Joyent is actively developing Prometheus and Grafana services for use in Triton
and Manta. [RFD 150](https://github.com/joyent/rfd/tree/master/rfd/0150)
describes the current plan and status.


## Setup for Triton

First ensure that [CMON](https://github.com/joyent/triton-cmon) and
[CNS](https://github.com/joyent/triton-cns) are set up in your TritonDC,
typically via:

    sdcadm post-setup cns [OPTIONS]
    sdcadm post-setup cmon [OPTIONS]

Then run the following from your TritonDC's headnode global zone:

    sdcadm post-setup prometheus [OPTIONS]

## Setup for Manta

As with Triton above, ensure that CMON and CNS are deployed. Then, create a new
Manta config file with your desired number of Prometheus instances and update
using `manta-adm`, as described in the
[Manta Operator's Guide](https://joyent.github.io/manta/#upgrading-manta-components)

## Configuration

Primarily this VM runs a Prometheus server (as the "prometheus" SMF service).
The config files for that service are as follows. Note that "/data/..." is a
delegate dataset to persist through reprovisions -- the Prometheus time-series
database is stored here.

    /opt/triton/prometheus/etc/config.json        # SAPI config
    /opt/triton/prometheus/etc/prometheus.yml     # Prometheus config; generated
                                                  # from SAPI config
    /opt/triton/prometheus/keys/*                 # Key and cert for CMON auth

    /data/prometheus/data/*                       # Prometheus database

Like most Triton and Manta core services, a config-agent is used to gather some
config data. Unlike many core services, this VM uses an additional config
processing step to create the final prometheus config. At the time of writing,
this is to allow post-processing of the SAPI config variables to produce the
Prometheus config file. This code is pulled out into
`/opt/triton/prometheus/bin/prometheus-configure`, which runs from
`boot/setup.sh`, `boot/configure.sh`, and as the config-agent `post_cmd`.

## SAPI Configuration

There are some Prometheus service configuration options that can be set in SAPI.
Note that the default values listed here are the values that the instance's
setup scripts will use if the SAPI variables are unset. They may be overridden using application- and size-specific defaults if a Prometheus instance is
deployed using `sdcadm` or `manta-adm`.

| Key                            | Type    | Description |
| ------------------------------ | ------- | ----------- |
| **cmon\_domain**               | String  | Optional. The domain at which Prometheus should talk to this DC's CMON, e.g. "cmon.us-east-1.triton.zone". The actual endpoint is assumed to be https and port 9163. See notes below. |
| **cmon\_enforce\_certificate** | Bool    | Optional. This can be set to `true` to have Prometheus fail on TLS cert errors from a self-signed cert. This is false by default. |
| **scrape\_interval**           | Integer | Optional. The interval, in seconds, at which Prometheus should scrape its targets. Defaults to 10. |
| **scrape\_timeout**            | Integer | Optional. The amount of time, in seconds, that is allotted for each scrape to complete. Defaults to 10. |
| **evaluation\_interval**       | Integer | Optional. The interval, in seconds, at which Prometheus should evaluate its alerting rules. Defaults to 10. |

Prometheus gets its metrics from the DC's local CMON, typically over the
external network. To auth with CMON properly in a production environment,
Prometheus needs to know the appropriate CMON URL advertised to public DNS for
which it has a signed TLS certificate. This is what `cmon_domain` is for. If
this variable is not set, then this image will attempt to infer an appropriate
URL via querying the DC's local CNS. See `bin/prometheus-configure` for details.

An example setting some of these values:

    promSvc=$(sdc-sapi /services?name=prometheus | json -Ha uuid)
    sdc-sapi /services/$promSvc -X PUT \
        -d '{"metadata": {"cmon_domain": "mycmon.example.com", "cmon_enforce_certificate": true}}'


## CMON Auth

Prometheus needs to authenticate with the local CMON. To do this, the setup
script generates a certificate using the `bin/certgen` tool. This certificate
can be regenerated by running the tool manually.

### Name resolution

The Prometheus zone resolves names using
[CNS](https://github.com/joyent/triton-cns). To allow queries from an arbitrary
number of CNS servers and offload some traffic from CNS, the Prometheus zone
runs a BIND server that resolves the CNS names using zone transfer. The BIND
server forwards all requests outside of the CNS zone to external and binder
resolvers. BIND runs on localhost, and localhost is the only entry in
/etc/resolv.conf.

## Security

Prometheus listens on the admin and external networks. The firewall with the
[standard Triton rules](https://github.com/joyent/sdc-headnode/blob/34dbd8acd65523c844385a81239ea0a872750326/scripts/headnode.sh#L188-L228)
is enabled to disallow incoming requests on the external network.

Prometheus is on the external network so it can access CMON and work with CNS --
at least until CNS supports split horizon DNS to provide separate records on the
admin network. This is because CMON's Triton service discovery returns the CNS
domain names for Triton's core VMs.

Prometheus is on the admin network because Triton Grafana instances access
Triton and Manta Prometheus instances on the admin network.


## Troubleshooting

### Prometheus doesn't have Triton/Manta data

Prometheus gets its Triton (or Manta) data from CMON. Here are some things to
check if this appears to be failing:

- Does the following Prometheus query have any data?

        cpucap_cur_usage_percentage{alias=~"cnapi.+"}

- Does the Prometheus config (/opt/triton/prometheus/etc/prometheus.yml) look correct?

- Is Prometheus running? `svcs prometheus`

- Is BIND running? `svcs bind`

- Is `/etc/resolv.conf` correct? It should have `127.0.0.1` as its only
  nameserver entry.

- Has the `prometheus-configure` script errored out? It is run in two contexts
  -- to check, see if the `mdata:execute` service has failed
  (`svcs mdata:execute`), and check the `config-agent` logs for warnings
  (`grep prometheus-configure $(svcs -L config-agent) | bunyan`)

- Does the Prometheus log show errors? E.g. (newlines added for readability):

    ```
    $ tail `svcs -L prometheus`
    ...
    level=error ts=2018-09-28T18:42:33.715136969Z caller=triton.go:170
        component="discovery manager scrape"
        discovery=triton
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

## LX script

This repo also contains a script to set up an ad-hoc LX-branded zone running
Prometheus. One might find this script useful for setting up a Prometheus
instance for experimentation -- the user will be able to safely edit
configuration files manually without config-agent overwriting them. This script
can also be used in environments where the relevant Triton components
(sdcadm, CMON, manta-deployment) haven't been updated to versions that support
the native Prometheus service. Here's how to run the script:

Run `./setup-prometheus-adhoc.sh` from a Triton headnode. All CLI flags are
optional; here's an explanation of what each flag does:
- `-i` specifies that Prometheus should connect to CMON using insecure TLS; this
  flag is likely necessary in a development environment
- `-f` enables the Prometheus zone's firewall on the external network
- `-r <comma-separated list of resolver IPs>` gives the Prometheus zone extra
  DNS resolvers; common values to include are the CNS zone's IP and the IP of
  a resolver for the public internet
- `-s <server UUID>` specifies which server in the Triton deployment to
  provision the zone on; the default is the server on which the script is being
  run
- `-k <path to ssh key>` puts the specified key in the Prometheus zone's
  `authorized_keys` file to allow ssh access

An appropriate invocation for a development setup would be:

    ./setup-prometheus-adhoc.sh \
    -i \
    -r <CNS IP>,8.8.8.8 \
    -k /root/.ssh/sdc.id_rsa.pub

An appropriate invocation for a production environment would be:

    ./setup-prometheus-adhoc.sh \
    -f \
    -r <CNS IP>,8.8.8.8 \
    -s <server UUID> \
    -k /root/.ssh/sdc.id_rsa.pub

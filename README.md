# triton-prometheus

A repo with tooling to setup Prometheus and Grafana in a TritonDC for metrics
and monitoring of Triton itself. The goal is to make it easy (and somewhat
standardized, to simplify collaboration) to work with and monitor TritonDC
metrics.

## Status

For now this just houses lowly bash scripts for setting up prometheus0
and grafana0 zones on a Triton headnode. Eventually this might turn into a core
TritonDC "prometheus" and "grafana" services.

## How to deploy Prometheus and Grafana for monitoring Triton

**NOTE**: the `setup-prometheus.sh` and `setup-grafana.sh` scripts are effectively
deprecated -- the `setup-*-prod.sh` scripts implement all of their
functionality, plus a number of additional features.

### Setting up Prometheus

Run `./setup-prometheus-prod.sh` from a Triton headnode. All CLI flags are
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

	./setup-prometheus-prod.sh \
	-i \
	-r <CNS IP>,8.8.8.8 \
	-k /root/.ssh/sdc.id_rsa.pub

An appropriate invocation for a production environment would be:

	./setup-prometheus-prod.sh \
	-f \
	-r <CNS IP>,8.8.8.8 \
	-s <server UUID> \
	-k /root/.ssh/sdc.id_rsa.pub

### Setting up Grafana

Run `./setup-grafana-prod.sh` from a Triton headnode. All CLI flags are
optional; here's an explanation of what each flag does:
- `-s <server UUID>` specifies which server in the Triton deployment to
  provision the zone on; the default is the server on which the script is being
  run
- `-k <path to ssh key>` puts the specified key in the Grafana zone's
  `authorized_keys` file to allow ssh access

An appropriate invocation for a development setup would be:

	./setup-grafana-prod.sh \
	-k /root/.ssh/sdc.id_rsa.pub

An appropriate invocation for a production environment would be:

	./setup-grafana-prod.sh \
	-s <server UUID> \
	-k /root/.ssh/sdc.id_rsa.pub

### (DEPRECATED) Instructions for old scripts

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

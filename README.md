# triton-prometheus

A repo with tooling to setup Prometheus and Grafana in a TritonDC
for metrics and monitoring of Triton itself. The goal is to make
it easy (and somewhat standardized, to simplify collaboration) to
work with and monitor TritonDC metrics.

## Status

For now this is just notes and merged bash scripts from JoshW,
Dylan, and Trent. Eventually this might turn into a core TritonDC
"prometheus" service (or even two separate ones for each of
Prometheus and Grafana).

## How to deploy a prometheus0 zone to COAL

Assuming you have something like this in your "~/.ssh/config":

	Host coal
		User root
		Hostname 10.99.99.7
		StrictHostKeyChecking no
		UserKnownHostsFile /dev/null

Run this:

    ./setup.sh coal


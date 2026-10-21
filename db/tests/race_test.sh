#!/usr/bin/env bash
# Concurrency test: unsafe provisioning over-allocates, the locked version does not.
bash "$(dirname "$0")/../demo/run_race.sh" --assert

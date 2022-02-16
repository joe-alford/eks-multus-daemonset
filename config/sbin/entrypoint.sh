#!/bin/bash
set -e

/sbin/multus-config.sh

#this just calls the multus script. For some reason, putting a `while true` type loop into the 
#entrypoint of a container doesn't seem to work, but calling one immediately afterwards is fine
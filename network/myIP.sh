#!/bin/bash
curl -s 'https://api.ipify.org?format=json' | jq -r .ip | awk '{print $1 "/32"}'

#!/usr/bin/env bash
end=$((SECONDS+$1))
while [ $SECONDS -lt $end ]; do
  echo "dummy $(date +%s%N)" >> /var/log/demo.log
done

#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 1 ]] || { echo "Usage: $0 results.csv [more.csv ...]"; exit 1; }

awk -F, 'BEGIN{
  OFS=",";
}
NR==1 { next } # skip headers from each file
{
  key=$2 FS $5; # pkg + mode
  cnt[key]++;

  e=$7+0; t=$8+0;

  sumE[key]+=e; sumT[key]+=t;

  if(!(key in minE) || e<minE[key]) minE[key]=e;
  if(!(key in maxE) || e>maxE[key]) maxE[key]=e;

  if(!(key in minT) || t<minT[key]) minT[key]=t;
  if(!(key in maxT) || t>maxT[key]) maxT[key]=t;
}
END{
  print "pkg","mode","n","elapsed_avg_s","elapsed_min_s","elapsed_max_s","taskclk_avg_ms","taskclk_min_ms","taskclk_max_ms";
  for (k in cnt) {
    split(k,a,FS); pkg=a[1]; mode=a[2];
    eavg = (cnt[k]? sumE[k]/cnt[k] : 0);
    tavg = (cnt[k]? sumT[k]/cnt[k] : 0);
    printf "%s,%s,%d,%.6f,%.6f,%.6f,%.2f,%.2f,%.2f\n",
      pkg,mode,cnt[k],eavg,minE[k],maxE[k],tavg,minT[k],maxT[k];
  }
}' "$@"

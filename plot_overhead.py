#!/usr/bin/env python3
import argparse, os, glob
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

def load_summary(summary_csv=None, results_glob="results*_*.csv"):
    if summary_csv and os.path.exists(summary_csv):
        return pd.read_csv(summary_csv)
    # Build a quick summary from raw results if no summary file given
    paths = sorted(glob.glob(results_glob))
    if not paths:
        raise SystemExit("No results*.csv files found and no summary CSV provided.")
    frames=[]
    for p in paths:
        df=pd.read_csv(p, na_values=["NA","","<not supported>"])
        frames.append(df)
    df=pd.concat(frames, ignore_index=True)
    for c in ["elapsed_s","task_clock_ms","threads","exit_code"]:
        if c in df.columns:
            df[c]=pd.to_numeric(df[c], errors="coerce")
    df = df[df["exit_code"].fillna(0)==0].copy()
    grp=["pkg","input","threads","mode"]
    agg={"elapsed_s":["count","mean","min","max"]}
    if "task_clock_ms" in df.columns:
        agg["task_clock_ms"]=["count","mean","min","max"]
    summ=df.groupby(grp).agg(agg)
    summ.columns=[f"{m}_{stat}" for m,stat in summ.columns]
    summ=summ.reset_index()
    return summ

def pick_rows_for_metric(summ, metric, input_filter=None):
    # Build per-app records: choose the row (per mode) with the largest run count
    need_cols=[f"{metric}_mean", f"{metric}_min", f"{metric}_max", f"{metric}_count"]
    for c in need_cols:
        if c not in summ.columns:
            raise SystemExit(f"Metric columns missing in summary: {c}")
    records=[]
    for pkg in sorted(summ["pkg"].unique()):
        sub=summ[summ["pkg"]==pkg]
        if input_filter:
            sub=sub[sub["input"]==input_filter]
            if sub.empty:  # fallback to any
                sub=summ[summ["pkg"]==pkg]
        row={}
        row["pkg"]=pkg
        for mode in ["baseline","ebpf"]:
            s=sub[sub["mode"]==mode]
            if s.empty:
                continue
            s=s.sort_values(by=[f"{metric}_count","threads"], ascending=[False,True])
            r=s.iloc[0]
            row[f"{mode}_mean"]=r[f"{metric}_mean"]
            row[f"{mode}_min"]=r[f"{metric}_min"]
            row[f"{mode}_max"]=r[f"{metric}_max"]
        if ("baseline_mean" in row) and ("ebpf_mean" in row):
            records.append(row)
    return pd.DataFrame(records)

def plot_bars_minmax(df, metric, outpath, title=None, ylabel=None):
    if df.empty:
        raise SystemExit("Nothing to plot.")
    apps=list(df["pkg"])
    x=np.arange(len(apps))
    width=0.38

    b_means=df["baseline_mean"].values
    e_means=df["ebpf_mean"].values
    b_mins=df["baseline_min"].values
    b_maxs=df["baseline_max"].values
    e_mins=df["ebpf_min"].values
    e_maxs=df["ebpf_max"].values

    plt.figure(figsize=(10,5))
    bxs=x - width/2
    exs=x + width/2
    plt.bar(bxs, b_means, width, label="Baseline")
    plt.bar(exs, e_means, width, label="eBPF")

    # Whiskers: min..max
    for i in range(len(x)):
        plt.vlines(bxs[i], b_mins[i], b_maxs[i])
        plt.vlines(exs[i], e_mins[i], e_maxs[i])

    plt.xticks(x, apps, rotation=30, ha="right")
    plt.legend()
    plt.grid(axis="y", linestyle=":", linewidth=0.6)
    if title: plt.title(title)
    if ylabel: plt.ylabel(ylabel)
    plt.tight_layout()
    plt.savefig(outpath, dpi=200)
    print(f"[OK] Figure written: {outpath}")

def main():
    ap=argparse.ArgumentParser(description="Plot grouped bars with min/max whiskers (baseline vs eBPF).")
    ap.add_argument("--summary", help="Path to summary_by_pkg_mode CSV (optional). If omitted, will summarize from raw results*.csv.")
    ap.add_argument("--metric", choices=["elapsed","taskclock"], default="elapsed", help="Metric to plot.")
    ap.add_argument("--input", help="Filter by input label (e.g., simlarge). Optional.")
    ap.add_argument("--out", default=None, help="Output filename (PNG). If omitted, auto-named.")
    args=ap.parse_args()

    summ = load_summary(args.summary)
    metric = "elapsed_s" if args.metric=="elapsed" else "task_clock_ms"
    ylabel = "Seconds" if metric=="elapsed_s" else "Task clock (ms)"
    df = pick_rows_for_metric(summ, metric, input_filter=args.input)
    if df.empty:
        raise SystemExit("No paired (baseline & eBPF) data found for the selected metric/input.")
    # Consistent column names
    df=df.rename(columns={
        "baseline_mean":"baseline_mean","ebpf_mean":"ebpf_mean",
        "baseline_min":"baseline_min","baseline_max":"baseline_max",
        "ebpf_min":"ebpf_min","ebpf_max":"ebpf_max"
    })

    out = args.out or (f"figure_{args.metric}_minmax.png")
    ttl = f"{args.metric.capitalize()} — mean with min/max (baseline vs eBPF)"
    if args.input:
        ttl += f" — input={args.input}"
        base, ext = os.path.splitext(out)
        out = f"{base}_{args.input}{ext}"
    plot_bars_minmax(df, metric, out, title=ttl, ylabel=ylabel)

if __name__=="__main__":
    main()

#!/usr/bin/env python3
import argparse, glob, os, sys, datetime
import pandas as pd
import numpy as np

def load_results(files):
    patterns = files if files else ['results*_*.csv']
    paths = []
    for pat in patterns:
        paths.extend(glob.glob(pat))
    if not paths:
        sys.exit("No results*.csv files found.")
    frames = []
    for p in sorted(paths):
        df = pd.read_csv(p, na_values=["NA", "", "<not supported>"])
        # Standardize optional columns from perf runs
        for col in ["task_clock_ms","cycles","instructions","branches","branch_misses","ctx","cmigr","pgfaults"]:
            if col not in df.columns:
                df[col] = np.nan
        df["source_file"] = os.path.basename(p)
        frames.append(df)
    out = pd.concat(frames, ignore_index=True)
    # Coerce numeric
    num_cols = ["elapsed_s","task_clock_ms","cycles","instructions","branches","branch_misses","ctx","cmigr","pgfaults","threads","run_idx","exit_code"]
    for c in num_cols:
        if c in out.columns:
            out[c] = pd.to_numeric(out[c], errors="coerce")
    out["pkg"] = out["pkg"].astype(str)
    out["mode"] = out["mode"].astype(str)
    out["input"] = out["input"].astype(str)
    return out

def summarize(df):
    ok = df[df["exit_code"].fillna(0) == 0].copy()
    group = ["pkg","input","threads","mode"]
    metrics = ["elapsed_s","task_clock_ms"]
    agg = {m:["count","mean","std","min","median","max"] for m in metrics if m in ok.columns}
    summ = ok.groupby(group).agg(agg)
    summ.columns = [f"{m}_{stat}" for m,stat in summ.columns]
    summ = summ.reset_index().sort_values(["pkg","input","threads","mode"])
    return summ

def compute_overhead(summ, metric):
    needed = [f"{metric}_mean", f"{metric}_min", f"{metric}_max"]
    for c in needed:
        if c not in summ.columns: 
            return pd.DataFrame()
    idx = ["pkg","input","threads"]
    piv_mean = summ.pivot_table(index=idx, columns="mode", values=f"{metric}_mean")
    piv_min  = summ.pivot_table(index=idx, columns="mode", values=f"{metric}_min")
    piv_max  = summ.pivot_table(index=idx, columns="mode", values=f"{metric}_max")
    out = piv_mean.copy()
    if {"baseline","ebpf"}.issubset(out.columns):
        out["overhead_pct"] = (out["ebpf"] - out["baseline"]) / out["baseline"] * 100.0
    out = out.rename(columns={"baseline":f"{metric}_baseline_mean","ebpf":f"{metric}_ebpf_mean"})
    # Attach min/max (optional, helpful for plots later)
    if "baseline" in piv_min.columns:
        out[f"{metric}_baseline_min"] = piv_min["baseline"]
        out[f"{metric}_baseline_max"] = piv_max["baseline"]
    if "ebpf" in piv_min.columns:
        out[f"{metric}_ebpf_min"] = piv_min["ebpf"]
        out[f"{metric}_ebpf_max"] = piv_max["ebpf"]
    out = out.reset_index()
    return out

def macro_average_overhead(ov, metric):
    if ov.empty: 
        return pd.DataFrame()
    col = "overhead_pct"
    keep = ["pkg","input","threads",col]
    have = ov.dropna(subset=[col])[keep].copy()
    if have.empty:
        return pd.DataFrame()
    macro = have[col].mean()
    return pd.DataFrame({"metric":[metric], "macro_avg_overhead_pct":[macro]})

def main():
    ap = argparse.ArgumentParser(description="Summarize PARSEC results and compute overheads.")
    ap.add_argument("--files", nargs="*", help="CSV files or globs (default: results*_*.csv)")
    ap.add_argument("--out", default="reports", help="Output directory")
    ap.add_argument("--tag", default="", help="Optional tag for filenames")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    tag = (args.tag.strip()+"_") if args.tag else ""
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")

    df = load_results(args.files)
    df_ok = df[df["exit_code"].fillna(0) == 0].copy()
    df_ok.to_csv(os.path.join(args.out, f"{tag}raw_clean_{stamp}.csv"), index=False)

    summ = summarize(df)
    summ_path = os.path.join(args.out, f"{tag}summary_by_pkg_mode_{stamp}.csv")
    summ.to_csv(summ_path, index=False)

    ov_elapsed = compute_overhead(summ, "elapsed_s")
    ov_tclk    = compute_overhead(summ, "task_clock_ms")

    ov_elapsed_path = os.path.join(args.out, f"{tag}overhead_elapsed_{stamp}.csv")
    ov_tclk_path    = os.path.join(args.out, f"{tag}overhead_taskclock_{stamp}.csv")
    if not ov_elapsed.empty: ov_elapsed.to_csv(ov_elapsed_path, index=False)
    if not ov_tclk.empty:    ov_tclk.to_csv(ov_tclk_path, index=False)

    macro_rows = []
    m1 = macro_average_overhead(ov_elapsed, "elapsed_s")
    if not m1.empty: macro_rows.append(m1)
    m2 = macro_average_overhead(ov_tclk, "task_clock_ms")
    if not m2.empty: macro_rows.append(m2)
    macro = pd.concat(macro_rows, ignore_index=True) if macro_rows else pd.DataFrame()

    # Excel workbook
    xlsx = os.path.join(args.out, f"{tag}summary_{stamp}.xlsx")
    with pd.ExcelWriter(xlsx, engine="openpyxl") as xl:
        df.to_excel(xl, "raw_all", index=False)
        df_ok.to_excel(xl, "raw_success", index=False)
        summ.to_excel(xl, "summary", index=False)
        if not ov_elapsed.empty: ov_elapsed.to_excel(xl, "overhead_elapsed", index=False)
        if not ov_tclk.empty:    ov_tclk.to_excel(xl, "overhead_taskclock", index=False)
        if not macro.empty:      macro.to_excel(xl, "macro_overhead", index=False)

    # Brief console recap
    print(f"[OK] Wrote: {summ_path}")
    if not ov_elapsed.empty:
        print(f"[OK] Wrote: {ov_elapsed_path}")
        print("    Mean overhead (elapsed_s):",
              round(ov_elapsed['overhead_pct'].dropna().mean(), 4), "%")
    if not ov_tclk.empty:
        print(f"[OK] Wrote: {ov_tclk_path}")
        print("    Mean overhead (task_clock_ms):",
              round(ov_tclk['overhead_pct'].dropna().mean(), 4), "%")
    if not macro.empty:
        print("[OK] Macro overhead snapshot:")
        print(macro.to_string(index=False))
    print(f"[OK] Excel workbook: {xlsx}")

if __name__ == "__main__":
    main()

import json
import os
import pandas as pd
import matplotlib.pyplot as plt

DEFAULT_RESULTS_PATH = os.path.join(os.path.dirname(__file__), "..", "results", "results.json")

PYTHON_TELEMETRY_METRICS = [
    "python_parsing_time_ms",
    "python_computation_time_ms",
    "python_serialization_time_ms",
    "python_total_time_ms",
]


def _summarize(values, label):
    return {
        "Metric": label,
        "Count": len(values),
        "Mean": round(values.mean(), 2),
        "P50": round(values.median(), 2),
        "P95": round(values.quantile(0.95), 2),
        "P99": round(values.quantile(0.99), 2),
        "Min": round(values.min(), 2),
        "Max": round(values.max(), 2),
    }


def analyze_k6_results(filename=DEFAULT_RESULTS_PATH):
    data = []
    print(f"[*] Reading metrics from {filename}...")

    try:
        with open(filename, 'r') as f:
            for line in f:
                try:
                    data.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        print(f"[!] Error: {filename} not found. Run your k6 test first.")
        return

    df = pd.DataFrame(data)

    df['strategy'] = df['data'].apply(
        lambda x: x.get('tags', {}).get('strategy') if isinstance(x, dict) else None
    )
    df['value'] = df['data'].apply(
        lambda x: x.get('value') if isinstance(x, dict) else None
    )

    req_durations = df[(df['metric'] == 'http_req_duration') & df['value'].notna()].copy()

    if req_durations.empty:
        print("[!] No 'http_req_duration' metrics found in the dataset.")
        return

    strategies = sorted(s for s in req_durations['strategy'].dropna().unique())
    if not strategies:
        print("[!] No 'strategy' tag found on requests — falling back to pooled results.")
        strategies = [None]

    print("\n--- END-TO-END LATENCY BY STRATEGY (ms) ---")
    rows = []
    for strat in strategies:
        subset = req_durations if strat is None else req_durations[req_durations['strategy'] == strat]
        rows.append(_summarize(subset['value'], strat or "ALL"))
    latency_df = pd.DataFrame(rows)
    print(latency_df.to_markdown(index=False))

    for metric_name in PYTHON_TELEMETRY_METRICS:
        metric_df = df[(df['metric'] == metric_name) & df['value'].notna()]
        if metric_df.empty:
            continue
        print(f"\n--- {metric_name.upper()} BY STRATEGY (ms) ---")
        rows = []
        for strat in strategies:
            subset = metric_df if strat is None else metric_df[metric_df['strategy'] == strat]
            if subset.empty:
                continue
            rows.append(_summarize(subset['value'], strat or "ALL"))
        if rows:
            print(pd.DataFrame(rows).to_markdown(index=False))

    plt.figure(figsize=(9, 5), dpi=300)
    colors = ['#2b5c8f', '#c0392b', '#27ae60']
    for i, strat in enumerate(strategies):
        subset = req_durations if strat is None else req_durations[req_durations['strategy'] == strat]
        plt.hist(subset['value'], bins=60, alpha=0.55,
                  label=strat or "ALL", color=colors[i % len(colors)], edgecolor='black')

    plt.title('End-to-End Latency Distribution under Load', fontsize=13, fontweight='bold', pad=12)
    plt.xlabel('Request Latency (ms)', fontsize=11)
    plt.ylabel('Frequency (Request Count)', fontsize=11)
    plt.grid(True, linestyle='--', alpha=0.4)
    if len(strategies) > 1:
        plt.legend(title='Strategy')

    output_image = 'latency_distribution_plot.png'
    plt.savefig(output_image, bbox_inches='tight')
    print(f"\n[+] High-resolution chart successfully saved as '{output_image}'!")


if __name__ == "__main__":
    analyze_k6_results()
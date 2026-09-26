"""Table and figure writers shared by every analysis script, so all outputs drop into
the same paper in the same three table formats."""

import os
import re

import matplotlib.pyplot as plt

from run_dirs import as_output_dirs


def latex_text(text):
    """Escapes the LaTeX specials a caption can contain, leaving already-escaped ones."""
    return re.sub(r"(?<!\\)([%_&#])", r"\\\1", text)


def save_table(df, name, out, caption=None, label=None):
    """Writes df as .csv, .md and .tex. out: OutputDirs, or a directory holding tables/."""
    if df is None or df.empty:
        print(f"[!] Skipping empty table: {name}")
        return
    out = as_output_dirs(out)
    os.makedirs(out.tables, exist_ok=True)
    stem = os.path.join(out.tables, f"{name}{out.suffix}")

    df.to_csv(f"{stem}.csv", index=False)
    with open(f"{stem}.md", "w") as f:
        f.write(df.to_markdown(index=False))
    with open(f"{stem}.tex", "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n")
        # Caption precedes the tabular body so it renders above the table,
        # matching Elsevier/JSS style.
        if caption:
            f.write(f"\\caption{{{latex_text(caption)}}}\n")
        if label:
            f.write(f"\\label{{{label}}}\n")
        f.write(df.to_latex(index=False, escape=True))
        f.write("\\end{table}\n")
    print(f"[+] Table  -> {stem}.csv / .md / .tex")


def save_figure(fig, name, out):
    """Writes fig as .png (300 dpi) and .pdf and closes it. out: OutputDirs, or a
    directory holding figures/."""
    out = as_output_dirs(out)
    os.makedirs(out.figures, exist_ok=True)
    stem = os.path.join(out.figures, f"{name}{out.suffix}")
    fig.savefig(f"{stem}.png", dpi=300, bbox_inches="tight")
    fig.savefig(f"{stem}.pdf", bbox_inches="tight")
    plt.close(fig)
    print(f"[+] Figure -> {stem}.png / .pdf")

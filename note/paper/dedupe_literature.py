#!/usr/bin/env python3
"""
Literature de-duplication script.
Steps:
 1. Load CSV exported from Google Scholar or similar (expects columns: Title, DOI, Authors, Year, Cites, ...).
 2. Normalize fields (title casefold, strip punctuation/stopwords, collapse whitespace; DOI lower).
 3. Group by DOI when DOI present (DOI exact match strongest signal).
 4. For entries without DOI, cluster by fuzzy title similarity (combined ratio of SequenceMatcher + Jaccard of token sets).
 5. Within ambiguous clusters, further split if Years far apart or author overlap too small.
 6. Output two files:
      - deduped.csv: one representative per cluster (highest Cites preferred; else earliest Year; else first seen)
      - clusters.csv: mapping of cluster_id -> original row index + title + DOI

Heuristics adjustable via CLI flags.

Usage:
  python dedupe_literature.py --input PoPCites.csv --out deduped.csv --clusters clusters.csv \
      --title-threshold 0.84 --min-author-overlap 0.2

Dependencies: only standard library unless you enable optional --use-rapidfuzz (pip install rapidfuzz).
"""
import csv
import argparse
import re
import sys
from collections import defaultdict
from difflib import SequenceMatcher
from math import inf

try:
    from rapidfuzz import fuzz  # optional for speed
    HAVE_RAPIDFUZZ = True
except Exception:
    HAVE_RAPIDFUZZ = False

PUNCT_RE = re.compile(r"[\.,:;!\?\-\(\)\[\]\{\}\'\"/\\]")
MULTI_WS_RE = re.compile(r"\s+")
STOP_WORDS = set(["a","an","the","of","for","and","on","in","with","to","via","by","at","into","from"])

def norm_doi(doi: str) -> str:
    if not doi:
        return ""
    doi = doi.strip().lower()
    doi = doi.replace("https://doi.org/", "")
    return doi

def tokenize_title(t: str):
    t = PUNCT_RE.sub(" ", t.lower())
    t = MULTI_WS_RE.sub(" ", t).strip()
    tokens = [w for w in t.split(" ") if w and w not in STOP_WORDS]
    return tokens

def norm_title(t: str) -> str:
    tokens = tokenize_title(t)
    return " ".join(tokens)

def jaccard(a:set, b:set) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if inter == 0:
        return 0.0
    return inter / len(a | b)

def fuzzy_score(t1_raw:str, t2_raw:str) -> float:
    # Combined score from SequenceMatcher ratio and token Jaccard
    if not t1_raw or not t2_raw:
        return 0.0
    t1 = norm_title(t1_raw)
    t2 = norm_title(t2_raw)
    if t1 == t2:
        return 1.0
    set1, set2 = set(t1.split()), set(t2.split())
    jac = jaccard(set1, set2)
    if HAVE_RAPIDFUZZ:
        sm = fuzz.token_sort_ratio(t1, t2) / 100.0
    else:
        sm = SequenceMatcher(None, t1, t2).ratio()
    # Weighted combination
    return 0.55*sm + 0.45*jac

def author_list(raw:str):
    if not raw:
        return []
    # Authors format: "A Name, B Name" or quoted.
    parts = [p.strip().lower() for p in raw.replace(";", ",").split(",") if p.strip()]
    # Merge initials and surnames heuristically (keep as is)
    return parts

def author_overlap(a, b) -> float:
    if not a or not b:
        return 0.0
    sa, sb = set(a), set(b)
    inter = len(sa & sb)
    return inter / min(len(sa), len(sb))

def choose_rep(records):
    # Prefer highest Cites then earliest Year then first
    best = None
    for r in records:
        cites = r.get('Cites')
        try:
            cites_val = int(cites) if cites else -1
        except Exception:
            cites_val = -1
        try:
            year_val = int(r.get('Year') or 9999)
        except Exception:
            year_val = 9999
        if best is None:
            best = (cites_val, -year_val, r)
        else:
            if (cites_val, -year_val) > (best[0], best[1]):
                best = (cites_val, -year_val, r)
    return best[2] if best else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input','-i', required=True)
    ap.add_argument('--out','-o', required=True, help='Deduped output CSV')
    ap.add_argument('--clusters', required=False, help='Optional cluster mapping CSV')
    ap.add_argument('--title-threshold', type=float, default=0.85, help='Fuzzy title similarity threshold for clustering')
    ap.add_argument('--min-author-overlap', type=float, default=0.2, help='Minimum fractional author overlap to accept cluster merge when ambiguous')
    ap.add_argument('--max-year-span', type=int, default=5, help='If year difference exceeds this inside a title cluster, split')
    ap.add_argument('--use-rapidfuzz', action='store_true', help='Force usage of rapidfuzz (if installed)')
    args = ap.parse_args()

    global HAVE_RAPIDFUZZ
    if args.use_rapidfuzz and not HAVE_RAPIDFUZZ:
        print('rapidfuzz not installed; pip install rapidfuzz for speed', file=sys.stderr)

    rows = []
    with open(args.input, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        for idx, row in enumerate(reader):
            row['_row_index'] = idx
            row['_doi_norm'] = norm_doi(row.get('DOI',''))
            row['_title_norm'] = norm_title(row.get('Title',''))
            row['_authors_list'] = author_list(row.get('Authors',''))
            rows.append(row)

    # 1. Group by DOI
    doi_groups = defaultdict(list)
    no_doi_rows = []
    for r in rows:
        if r['_doi_norm']:
            doi_groups[r['_doi_norm']].append(r)
        else:
            no_doi_rows.append(r)

    clusters = []  # list of lists of records
    for g in doi_groups.values():
        clusters.append(g)

    # 2. Fuzzy cluster rows without DOI
    unassigned = no_doi_rows[:]
    visited = set()
    for i, r in enumerate(unassigned):
        if r['_row_index'] in visited:
            continue
        current_cluster = [r]
        visited.add(r['_row_index'])
        for j in range(i+1, len(unassigned)):
            cand = unassigned[j]
            if cand['_row_index'] in visited:
                continue
            score = fuzzy_score(r['Title'], cand['Title'])
            if score >= args.title_threshold:
                # Basic author/year constraints
                yrs_ok = True
                try:
                    ry = int((r.get('Year') or '0'))
                    cy = int((cand.get('Year') or '0'))
                    if ry and cy and abs(ry-cy) > args.max_year_span:
                        yrs_ok = False
                except Exception:
                    pass
                ov = author_overlap(r['_authors_list'], cand['_authors_list'])
                if yrs_ok and (ov >= args.min_author_overlap or (not r['_authors_list'] and not cand['_authors_list'])):
                    current_cluster.append(cand)
                    visited.add(cand['_row_index'])
        clusters.append(current_cluster)

    # 3. Build representative list
    reps = []
    for cl in clusters:
        rep = choose_rep(cl)
        if rep:
            reps.append(rep)

    # 4. Write deduped
    out_fields = [c for c in fieldnames if c]
    if '_cluster_id' not in out_fields:
        out_fields.append('_cluster_id')
    if '_row_index' not in out_fields:
        out_fields.append('_row_index')

    cluster_ids = {}
    for cid, cl in enumerate(clusters):
        for r in cl:
            cluster_ids[r['_row_index']] = cid

    with open(args.out, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=out_fields)
        w.writeheader()
        for rep in reps:
            rep_out = {k: rep.get(k,'') for k in out_fields}
            rep_out['_cluster_id'] = cluster_ids.get(rep['_row_index'])
            w.writerow(rep_out)

    if args.clusters:
        with open(args.clusters, 'w', newline='', encoding='utf-8') as f:
            cw = csv.writer(f)
            cw.writerow(['cluster_id','row_index','DOI_norm','Title','Authors','Year'])
            for cid, cl in enumerate(clusters):
                for r in cl:
                    cw.writerow([cid, r['_row_index'], r['_doi_norm'], r.get('Title',''), r.get('Authors',''), r.get('Year','')])

    print(f'Deduped {len(rows)} -> {len(reps)} (clusters={len(clusters)})')

if __name__ == '__main__':
    main()

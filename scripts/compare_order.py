#!/usr/bin/env python3
"""Compare an exported order-probe JSON to an independently transcribed Photos CSV.
Only records a manual comparison, never proves USB or resource preservation.
"""
import argparse, csv, json, sys
from pathlib import Path

def compare(snapshot, rows):
    members = snapshot['members']
    if snapshot['authorization'] != 'full': raise ValueError('Full library permission required for O-01/O-02')
    if len(members) != 20 or len(rows) != 20: raise ValueError('Exactly 20 members and 20 Photos observations required')
    for sequence, key in [(members,'localIdentifier'),(rows,'localIdentifier')]:
        if len({row[key] for row in sequence}) != 20 or any(not row[key].strip() for row in sequence): raise ValueError('Identifiers must be nonempty and unique')
        if [int(row['ordinal']) for row in sequence] != list(range(1,21)): raise ValueError('Ordinal must be contiguous 1...20')
    return [index+1 for index,(a,b) in enumerate(zip(members,rows)) if a['localIdentifier'] != b['localIdentifier']]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot',type=Path); parser.add_argument('photos_csv',type=Path)
    parser.add_argument('--observer',required=True); parser.add_argument('--test-id',choices=['O-01','O-02'],required=True)
    parser.add_argument('--evidence-note',required=True,help='Photos custom sort, numbered visual mapping and device details')
    args=parser.parse_args()
    try:
        snapshot=json.loads(args.snapshot.read_text())
        with args.photos_csv.open(newline='') as f: rows=list(csv.DictReader(f))
        diff=compare(snapshot,rows)
        print(json.dumps({'testID':args.test_id,'status':'FAIL' if diff else 'MANUAL_COMPARISON_PASS',
                          'mismatchedOrdinals':diff,'observer':args.observer,'note':args.evidence_note,
                          'snapshotBuild':snapshot['build'],'systemVersion':snapshot['systemVersion'],
                          'fetchMode':snapshot['fetchMode'],'scope':'manual source order only; no restore or USB claims'},ensure_ascii=False,indent=2))
        return 1 if diff else 0
    except Exception as e: print(json.dumps({'status':'INVALID_EVIDENCE','error':str(e)})); return 2
if __name__=='__main__': sys.exit(main())

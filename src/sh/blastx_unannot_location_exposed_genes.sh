#!/usr/bin/env bash

set -eu

blastx \
	-query output/exposed/location_no_annot/degs_no_annot.fasta \
	-db bin/db/blastdb/nr/nr \
	-num_threads 50 \
	-outfmt "6 std salltitles" > output/exposed/location_no_annot/blastx_titles.outfmt6
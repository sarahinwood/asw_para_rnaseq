#!/usr/bin/env python3
import pathlib2
import os
import pandas

#############
# FUNCTIONS #
#############

def resolve_path(x):
    return(str(pathlib2.Path(x).resolve(strict=False)))

def find_read_files(read_dir):
#Make list of files
    path_generator = os.walk(read_dir, followlinks = True)
    my_files = list((dirpath, filenames)
        for (dirpath, dirname, filenames)
        in path_generator)
#Make new dictionary & populate with files (flowcell = key)
    my_fastq_files = {}
    for dirpath, filenames in my_files:
        for filename in filenames:
            if filename.endswith('.fastq.gz'):
                my_flowcell = pathlib2.Path(dirpath).name
                my_fastq = str(pathlib2.Path(dirpath,filename))
                if my_flowcell in my_fastq_files:
                    my_fastq_files[my_flowcell].append(my_fastq)
                else:
                    my_fastq_files[my_flowcell]= []
                    my_fastq_files[my_flowcell].append(my_fastq)
    return(my_fastq_files)

def sample_name_to_fastq(wildcards):
    sample_row = sample_key[sample_key['Sample_name'] == wildcards.sample]
    sample_id = sample_row.iloc[-1]['OGF_sample_ID']
    sample_flowcell = sample_row.iloc[-1]['Flow_cell']
    sample_all_fastq = [x for x in all_fastq[sample_flowcell]
                        if '-{}-'.format(sample_id) in x]
    sample_r1 = sorted(list(x for x in sample_all_fastq
                            if '_R1_' in os.path.basename(x)))
    sample_r2 = sorted(list(x for x in sample_all_fastq
                            if '_R2_' in os.path.basename(x)))
    return({'r1': sample_r1, 'r2': sample_r2})

###########
# GLOBALS #
###########

read_dir = 'data/reads'

sample_key_file = 'data/sample_key.csv'

bbduk_adapters = '/adapters.fa'

#containers
bbduk_container = 'shub://TomHarrop/singularity-containers:bbmap_38.00'
salmon_container = 'shub://TomHarrop/singularity-containers:salmon_0.11.1'

#########
# SETUP #
#########
# generate name to filename dictionary
all_fastq = find_read_files(read_dir)

sample_key = pandas.read_csv(sample_key_file)

all_samples = sorted(set(sample_key['Sample_name']))

#########
# RULES #
#########

rule target:
    input:
     expand('output/bbduk_trim/{sample}_r1.fq.gz', sample = all_samples),
     expand('output/bbduk_trim/{sample}_r2.fq.gz', sample = all_samples),
     expand('output/salmon/{sample}_quant/quant.sf', sample = all_samples),
     expand('output/unmapped/unmapped_names/fixed_names_{sample}.txt', sample = all_samples),
     expand('output/unmapped/filtered_unmapped/{sample}_r1.fq.gz', sample= all_samples),
     'output/corset/clusters.txt'

rule corset:
    input:
        salmon_eq = expand('output/salmon/{sample}_quant/aux_info/eq_classes.txt', sample=all_samples)
    output:
        'output/corset/clusters.txt',
        'output/corset/counts.txt'
    params:
        wd = 'output/corset',
        corset = resolve_path('bin/corset/corset'),
        input = resolve_path('output/salmon/*_quant/aux_info/eq_classes.txt')
    threads:
        20
    log:
        str(pathlib2.Path(resolve_path('output/logs/salmon/'),
                            'corset.log'))
    shell:
        'cd {params.wd} || exit 1 ; '
        '{params.corset} '
        '-g 1,2,3,4,5,1,2,3,4,5,6,1,2,3,4,5,6 '
        '-n L1_2h_A_non-purified-replacement,L1_4h_A,L1_30m_A,L1_Ex_H,L1_NC_A,L2_2h_A,L2_4h_A,L2_30m_A,L2_Ex_H,L2_NC_A,L2_NC_H,R1_2h_A,R1_4h_A,R1_30m_A,R1_Ex_H,R1_NC_A,R1_NC_H '
        '-i salmon_eq_classes '
        '{params.input} '
        '&>{log}'

rule filter_unmapped_reads:
    input:
        r1 = 'output/bbduk_trim/{sample}_r1.fq.gz',
        r2 = 'output/bbduk_trim/{sample}_r2.fq.gz',
        unmapped_names = 'output/unmapped/unmapped_names/fixed_names_{sample}.txt'
    output:
        fil_r1 = 'output/unmapped/filtered_unmapped/{sample}_r1.fq.gz',
        fil_r2 = 'output/unmapped/filtered_unmapped/{sample}_r2.fq.gz'
    singularity:
        bbduk_container
    threads:
        20
    log:
        'output/logs/filter_unmapped/filter_unmapped_reads_{sample}.log'
    shell:
        'filterbyname.sh '
        'in={input.r1} '
        'in2={input.r2} '
        'include=t '
        'names={input.unmapped_names} '
        'out={output.fil_r1} '
        'out2={output.fil_r2} '
        '&> {log}'

rule fix_unmapped_read_names:
    input:
        unmapped_names = 'output/salmon/{sample}_quant/aux_info/unmapped_names.txt'
    output:
        fixed_names = 'output/unmapped/unmapped_names/fixed_names_{sample}.txt'
    singularity:
        'shub://TomHarrop/singularity-containers:r_3.5.0'
    threads:
        20
    log:
        'output/logs/r/fix_names_{sample}.log'
    script:
        'src/fix_unmapped_read_names.R'

rule asw_salmon_quant:
    input:
        index_output = 'output/salmon/transcripts_index/hash.bin',
        left = 'output/bbduk_trim/{sample}_r1.fq.gz',
        right = 'output/bbduk_trim/{sample}_r2.fq.gz'
    output:
        quant = 'output/salmon/{sample}_quant/quant.sf',
        eq = 'output/salmon/{sample}_quant/aux_info/eq_classes.txt',
        unmapped = 'output/salmon/{sample}_quant/aux_info/unmapped_names.txt'
    params:
        index_outdir = 'output/salmon/transcripts_index',
        outdir = 'output/salmon/{sample}_quant'
    threads:
        20
    singularity:
        salmon_container
    log:
        'output/logs/salmon/asw_salmon_quant_{sample}.log'
    shell:
        'salmon quant '
        '-i {params.index_outdir} '
        '-l ISR '
        '--dumpEq '
        '-1 {input.left} '
        '-2 {input.right} '
        '-o {params.outdir} '
        '--writeUnmappedNames '
        '-p {threads} '
        '&> {log}'

rule asw_salmon_index:
    input:
        transcriptome_length_filtered = 'data/isoforms_by_length.fasta'
    output:
        'output/salmon/transcripts_index/hash.bin'
    params:
        outdir = 'output/salmon/transcripts_index'
    threads:
        20
    singularity:
        salmon_container
    log:
        'output/logs/asw_salmon_index.log'
    shell:
        'salmon index '
        '-t {input.transcriptome_length_filtered} '
        '-i {params.outdir} '
        '-p {threads} '
        '&> {log}'

rule bbduk_trim:
    input:
        r1 = 'output/joined/{sample}_r1.fq.gz',
        r2 = 'output/joined/{sample}_r2.fq.gz'
    output:
        r1 = 'output/bbduk_trim/{sample}_r1.fq.gz',
        r2 = 'output/bbduk_trim/{sample}_r2.fq.gz'
    params:
        adapters = bbduk_adapters
    log:
        'output/logs/bbduk_trim/{sample}.log'
    threads:
        20
    singularity:
        bbduk_container
    shell:
        'bbduk.sh '
        'in={input.r1} '
        'in2={input.r2} '
        'out={output.r1} '
        'out2={output.r2} '
        'ref={params.adapters} '
        'ktrim=r k=23 mink=11 hdist=1 tpe tbo qtrim=r trimq=15 '
        '&> {log}'

rule cat_reads:
    input:
        unpack(sample_name_to_fastq)
    output: 
        r1 = temp('output/joined/{sample}_r1.fq.gz'),
        r2 = temp('output/joined/{sample}_r2.fq.gz')
    threads:
        1
    shell:
        'cat {input.r1} > {output.r1} & '
        'cat {input.r2} > {output.r2} & '
        'wait'




import csv
import sys
import urllib.request

TMPDIR = "/scratch/tereiter/" # TODO: update tmpdir based on computing env, or remove tmpdir invocation in resources
#GTDB_SPECIES = ['s__Pseudomonas_aeruginosa']
GTDB_SPECIES = ['s__Bacillus_pumilus']

class Checkpoint_GrabAccessions:
    """
    Define a class to simplify file specification from checkpoint 
    (e.g. solve for {acc} wildcard without needing to specify a function
    for each arm of the DAG that uses the acc wildcard). 
    This approach is documented at this url: 
    http://ivory.idyll.org/blog/2021-snakemake-checkpoints.html
    """
    def __init__(self, pattern):
        self.pattern = pattern

    def get_genome_accs(self, gtdb_species):
        acc_csv = f'outputs/gtdb_genomes_by_species/{gtdb_species}.csv'
        assert os.path.exists(acc_csv)

        genome_accs = []
        with open(acc_csv, 'rt') as fp:
           r = csv.DictReader(fp)
           for row in r:
               acc = row['ident']
               genome_accs.append(acc)
        print(f'loaded {len(genome_accs)} accessions from {acc_csv}.')

        return genome_accs

    def __call__(self, w):
        global checkpoints

        # wait for the results of rule 'grab_species_accessions'; 
        # this will trigger exception until that rule has been run.
        checkpoints.grab_species_accessions.get(**w)

        # parse accessions in gather output file
        genome_accs = self.get_genome_accs(w.gtdb_species)

        p = expand(self.pattern, acc=genome_accs, **w)
        return p

rule all:
    input:
        # generate pangenome and annotate with eggnog
        #expand("outputs/gtdb_genomes_roary_eggnog/{gtdb_species}.emapper.annotations", gtdb_species = GTDB_SPECIES),
        # generate pantranscriptome and index it with salmon
        expand("outputs/gtdb_genomes_salmon_index/{gtdb_species}/info.json", gtdb_species = GTDB_SPECIES)

##############################################################
## Generate reference transcriptome using pangenome analysis
##############################################################

rule download_gtdb_lineages:
    output: "inputs/gtdb-rs202.taxonomy.v2.csv"
    resources:
        mem_mb = 4000
    threads: 1
    shell:"""
    wget -O {output} https://osf.io/p6z3w/download
    """
 
# The outputs of this rule are used by the class Checkpoint_GrabAccessions.
# The new wildcard, acc, is encoded in the "ident" column of the output
# file "accessions". 
checkpoint grab_species_accessions:
    input: gtdb_lineages = "inputs/gtdb-rs202.taxonomy.v2.csv"
    output: 
        accessions = "outputs/gtdb_genomes_by_species/{gtdb_species}.csv",
        charcoal_lineages = "outputs/gtdb_genomes_by_species/{gtdb_species}_charcoal_lineages.csv"
    resources:
        mem_mb = 4000
    threads: 1
    script: "scripts/grab_species_accessions.R"

rule make_genome_info_csv:
    output:
        csv = 'inputs/gtdb_genomes/{gtdb_species}/{acc}.info.csv'
    conda: "envs/download_genomes.yml"
    resources:
        mem_mb = 8000
    threads: 1
    shell: """
    python scripts/genbank_genomes.py {wildcards.acc} --output {output.csv}
    """

rule download_matching_genomes:
    input:
        csvfile = ancient('inputs/gtdb_genomes/{gtdb_species}/{acc}.info.csv')
    output:
        genome = "inputs/gtdb_genomes/{gtdb_species}/{acc}_genomic.fna.gz"
    resources:
        mem_mb = 500
    threads: 1
    run:
        with open(input.csvfile, 'rt') as infp:
            r = csv.DictReader(infp)
            rows = list(r)
            assert len(rows) == 1
            row = rows[0]
            acc = row['acc']
            assert wildcards.acc.startswith(acc)
            url = row['genome_url']
            name = row['ncbi_tax_name']

            print(f"downloading genome for acc {acc}/{name} from NCBI...",
                file=sys.stderr)
            with open(output.genome, 'wb') as outfp:
                with urllib.request.urlopen(url) as response:
                    content = response.read()
                    outfp.write(content)
                    print(f"...wrote {len(content)} bytes to {output.genome}",
                        file=sys.stderr)


rule sourmash_download_gtdb_database:
    output: "inputs/sourmash_dbs/gtdb-rs202.genomic.k31.zip" 
    resources:
        mem_mb = 1000,
        tmpdir = TMPDIR
    threads: 1
    shell:'''
    wget -O {output} https://osf.io/94mzh/download
    '''

rule charcoal_generate_genome_list:
    input:  ancient(Checkpoint_GrabAccessions("inputs/gtdb_genomes/{{gtdb_species}}/{acc}_genomic.fna.gz"))
    output: "outputs/charcoal_conf/charcoal_{gtdb_species}.genome-list.txt"
    threads: 1
    resources:
        mem_mb=500,
        tmpdir = TMPDIR
    params: genome_dir = lambda wildcards: "inputs/gtdb_genomes/" + wildcards.gtdb_species
    shell:'''
    ls {params.genome_dir}/*fna.gz | xargs -n 1 basename > {output} 
    '''

rule charcoal_generate_conf_file:
    input:
        genomes = ancient(Checkpoint_GrabAccessions("inputs/gtdb_genomes/{{gtdb_species}}/{acc}_genomic.fna.gz")),
        genome_list = "outputs/charcoal_conf/charcoal_{gtdb_species}.genome-list.txt",
        charcoal_lineages = "outputs/gtdb_genomes_by_species/{gtdb_species}_charcoal_lineages.csv",
        db="inputs/sourmash_dbs/gtdb-rs202.genomic.k31.zip",
        db_lineages="inputs/gtdb-rs202.taxonomy.v2.csv"
    output:
        conf = "conf/charcoal-conf-{gtdb_species}.yml",
    params: 
        genome_dir = lambda wildcards: "inputs/gtdb_genomes/" + wildcards.gtdb_species,
        output_dir = lambda wildcards: "outputs/gtdb_genomes_charcoal/" + wildcards.gtdb_species 
    resources:
        mem_mb = 500,
        tmpdir = TMPDIR
    threads: 1
    run:
        with open(output.conf, 'wt') as fp:
            print(f"""\
output_dir: {params.output_dir}
genome_list: {input.genome_list}
genome_dir: {params.genome_dir}
provided_lineages: {input.charcoal_lineages}
match_rank: order
gather_db:
 - {input.db} 
lineages_csv: {input.db_lineages} 
strict: 1
""", file=fp)


checkpoint charcoal_decontaminate_genomes:
    input:
        genomes = ancient(Checkpoint_GrabAccessions("inputs/gtdb_genomes/{{gtdb_species}}/{acc}_genomic.fna.gz")),
        genome_list = "outputs/charcoal_conf/charcoal_{gtdb_species}.genome-list.txt",
        conf = "conf/charcoal-conf-{gtdb_species}.yml",
        charcoal_lineages = "outputs/gtdb_genomes_by_species/{gtdb_species}_charcoal_lineages.csv",
        db="inputs/sourmash_dbs/gtdb-rs202.genomic.k31.zip",
        db_lineages="inputs/gtdb-rs202.taxonomy.v2.csv"
    output: directory("outputs/gtdb_genomes_charcoal/{gtdb_species}/"),
    resources:
        mem_mb = 275000,
        tmpdir = TMPDIR
    benchmark: "benchmarks/charcoal_{gtdb_species}.txt"
    threads: 32
    conda: "envs/charcoal.yml"
    shell:'''
    python -m charcoal run {input.conf} -j {threads} clean --nolock --latency-wait 15 --rerun-incomplete
    '''

rule bakta_download_db:
    output: "inputs/bakta_db/db/version.json"
    threads: 1
    resources: mem_mb = 4000
    params: outdir = "inputs/bakta_db"
    conda: "envs/bakta.yml"
    shell:'''
    bakta_db download --output {params.outdir}
    '''

rule bakta_annotate_gtdb_genomes:
    input: 
        fna=ancient("outputs/gtdb_genomes_charcoal/{gtdb_species}/{acc}_genomic.fna.gz.clean.fa.gz"),
        db="inputs/bakta_db/db/version.json",
    output: 
        "outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.faa",
        "outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.gff3",
        "outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.fna",
        "outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.ffn",
    resources: 
        mem_mb = lambda wildcards, attempt: attempt * 16000 ,
        tmpdir= TMPDIR
    benchmark: "benchmarks/bakta_{gtdb_species}/{acc}.txt"
    conda: 'envs/bakta.yml'
    params: 
        dbdir="inputs/bakta_db/db/",
        outdir = lambda wildcards: 'outputs/gtdb_genomes_bakta/' + wildcards.gtdb_species,
        locus_tag = lambda wildcards: re.sub("[CF_\.]", "", wildcards.acc)
    threads: 1
    shell:'''
    bakta --threads {threads} --db {params.dbdir} --prefix {wildcards.acc} --output {params.outdir} \
        --locus {wildcards.acc} --locus-tag {params.locus_tag} --keep-contig-headers {input.fna}
    '''

def checkpoint_charcoal_decontaminate_genomes1(wildcards):
    # checkpoint_output encodes the output dir from the checkpoint rule.
    checkpoint_output = checkpoints.charcoal_decontaminate_genomes.get(**wildcards).output[0]    
    file_names = expand("outputs/gtdb_genomes_bakta/{{gtdb_species}}/{acc}.ffn",
                        acc = glob_wildcards(os.path.join(checkpoint_output, "{acc}_genomic.fna.gz.clean.fa.gz")).acc)
    return file_names

rule cat_annotated_sequences:
    input: checkpoint_charcoal_decontaminate_genomes1
    output: "outputs/gtdb_genomes_annotated_comb/{gtdb_species}_all_annotated_seqs.fa"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    benchmark:"benchmarks/cat_annotated_seqs_{gtdb_species}.txt"
    shell:'''
    cat {input} > {output}
    '''

# note clustering might not be necessary because of the pufferfish index underlying salmon indexing. 
rule cluster_annotated_sequences:
    input: "outputs/gtdb_genomes_annotated_comb/{gtdb_species}_all_annotated_seqs.fa"
    output: "outputs/gtdb_genomes_annotated_comb/{gtdb_species}_clustered_annotated_seqs.fa"
    threads: 1
    resources: 
        mem_mb=16000,
        tmpdir=TMPDIR
    conda: "envs/cdhit.yml"
    benchmark:"benchmarks/cluster_annotated_{gtdb_species}.txt"
    shell:'''
    cd-hit-est -c .95 -i {input} -o {output}
    '''

#########################################################
## generate pangenome
#########################################################

def checkpoint_charcoal_decontaminate_genomes2(wildcards):
    # checkpoint_output encodes the output dir from the checkpoint rule.
    checkpoint_output = checkpoints.charcoal_decontaminate_genomes.get(**wildcards).output[0]    
    file_names = expand("outputs/gtdb_genomes_bakta/{{gtdb_species}}/{acc}.gff3",
                        acc = glob_wildcards(os.path.join(checkpoint_output, "{acc}_genomic.fna.gz.clean.fa.gz")).acc)
    return file_names

rule roary_determine_pangenome:
    input: checkpoint_charcoal_decontaminate_genomes2,
    output: "outputs/gtdb_genomes_roary/{gtdb_species}/pan_genome_reference.fa"
    conda: 'envs/roary.yml'
    resources:
        mem_mb = lambda wildcards, attempt: attempt * 16000,
        tmpdir=TMPDIR
    benchmark: "benchmarks/roary_{gtdb_species}.txt"
    threads: 2
    params: 
        outdir = lambda wildcards: 'outputs/gtdb_genomes_roary/' + wildcards.gtdb_species
    shell:'''
    roary -r -e -n -f {params.outdir} -p {threads} -z {input}
    '''

rule translate_pangenome_for_annotations:
    input: 'outputs/gtdb_genomes_roary/{gtdb_species}/pan_genome_reference.fa' 
    output: 'outputs/gtdb_genomes_roary/{gtdb_species}/pan_genome_reference.faa' 
    conda: 'envs/emboss.yml'
    resources:
        mem_mb = 16000,
        tmpdir = TMPDIR
    benchmark: "benchmarks/transeq_{gtdb_species}.txt"
    threads: 2
    shell:'''
    transeq {input} {output}
    '''

rule eggnog_download_db:
    output: "inputs/eggnog_db/eggnog.db"
    threads: 1   
    resources: 
        mem_mb = 4000,
        tmpdir=TMPDIR
    params: datadir = "inputs/eggnog_db"
    conda: "envs/eggnog.yml"
    shell:'''
    download_eggnog_data.py -H -d 2 -y --data_dir {params.datadir}
    '''

rule eggnog_annotate_pangenome:
    input: 
        faa = "outputs/gtdb_genomes_roary/{gtdb_species}/pan_genome_reference.faa",
        db = 'inputs/eggnog_db/eggnog.db'
    output: "outputs/gtdb_genomes_roary_eggnog/{gtdb_species}.emapper.annotations"
    conda: 'envs/eggnog.yml'
    resources:
        mem_mb = 32000,
        tmpdir=TMPDIR
    benchmark: "benchmarks/eggnog_{gtdb_species}.txt"
    threads: 8
    params: 
        outdir = "outputs/gtdb_genomes_roary_eggnog/",
        dbdir = "inputs/eggnog_db"
    shell:'''
    mkdir -p tmp/
    emapper.py --cpu {threads} -i {input.faa} --output {wildcards.gtdb_species} \
       --output_dir {params.outdir} -m hmmer -d none --tax_scope auto \
       --go_evidence non-electronic --target_orthologs all --seed_ortholog_evalue 0.001 \
       --seed_ortholog_score 60 --override --temp_dir tmp/ \
       -d 2 --data_dir {params.dbdir}
    '''


############################################################
## Generate decoy sequences
############################################################

rule define_genome_regions_as_bed:
    input: ancient("outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.fna"),
    output: "outputs/gtdb_genomes_regions_bed/{gtdb_species}/{acc}_region.sizes"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    conda: "envs/samtools.yml"
    benchmark:"benchmarks/genome_regions_{gtdb_species}/{acc}.txt"
    shell:'''    
    samtools faidx {input}
    cut -f 1,2 {input}.fai | sort -n -k1 > {output}
    '''

rule filter_bakta_gff:
    input:  gff=ancient("outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.gff3"),
    output: gff=temp("outputs/gtdb_genomes_gff/{gtdb_species}/{acc}_filtered.gff3"),
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    conda: "envs/rtracklayer.yml"
    benchmark:"benchmarks/filter_gff_{gtdb_species}/{acc}.txt"
    script: "scripts/filter_gff.R"

rule sort_bakta_gff:
    input: gff="outputs/gtdb_genomes_gff/{gtdb_species}/{acc}_filtered.gff3",
    output: gff="outputs/gtdb_genomes_gff/{gtdb_species}/{acc}_filtered_sorted.gff3",
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    conda: "envs/bedtools.yml"
    benchmark:"benchmarks/sort_gff_{gtdb_species}/{acc}.txt"
    shell:'''
    sortBed -i {input} > {output}
    '''

rule complement_gff:
    input:
        gff="outputs/gtdb_genomes_gff/{gtdb_species}/{acc}_filtered_sorted.gff3",
        sizes= "outputs/gtdb_genomes_regions_bed/{gtdb_species}/{acc}_region.sizes"
    output:"outputs/gtdb_genomes_intergenic_bed/{gtdb_species}/{acc}.bed"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    conda: "envs/bedtools.yml"
    benchmark:"benchmarks/complement_gff_{gtdb_species}/{acc}.txt"
    shell:'''
    bedtools complement -i {input.gff} -g {input.sizes} > {output}
    '''

rule extract_intergenic_from_genome:
    input:
        fna=ancient("outputs/gtdb_genomes_bakta/{gtdb_species}/{acc}.fna"),
        bed="outputs/gtdb_genomes_intergenic_bed/{gtdb_species}/{acc}.bed"
    output:"outputs/gtdb_genomes_intergenic_seqs/{gtdb_species}/{acc}.fa"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    conda: "envs/bedtools.yml"
    benchmark:"benchmarks/extract_intergenic_{gtdb_species}/{acc}.txt"
    shell:'''
    bedtools getfasta -fi {input.fna} -bed {input.bed} -name -s > {output}
    '''

def checkpoint_charcoal_decontaminate_genomes3(wildcards):
    # checkpoint_output encodes the output dir from the checkpoint rule.
    checkpoint_output = checkpoints.charcoal_decontaminate_genomes.get(**wildcards).output[0]    
    file_names = expand("outputs/gtdb_genomes_intergenic_seqs/{{gtdb_species}}/{acc}.fa",
                        acc = glob_wildcards(os.path.join(checkpoint_output, "{acc}_genomic.fna.gz.clean.fa.gz")).acc)
    return file_names

rule cat_intergenic_sequences:
    input: checkpoint_charcoal_decontaminate_genomes3
    output: "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_all_intergenic_seqs.fa"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    benchmark:"benchmarks/cat_intergenic_{gtdb_species}.txt"
    shell:'''
    cat {input} > {output}
    '''

# note clustering might not be necessary because of the pufferfish index underlying salmon indexing. 
rule cluster_intergenic_sequences:
    input: "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_all_intergenic_seqs.fa"
    output: "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_clustered_intergenic_seqs.fa"
    threads: 1
    resources: 
        mem_mb=16000,
        tmpdir=TMPDIR
    conda: "envs/cdhit.yml"
    benchmark:"benchmarks/cluster_intergenic_{gtdb_species}.txt"
    shell:'''
    cd-hit-est -c 1 -i {input} -o {output}
    '''

###################################################
## Generate decoy-aware salmon transcriptome index
###################################################

rule grab_intergenic_sequence_names:
    input: "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_clustered_intergenic_seqs.fa"
    output: "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_clustered_intergenic_seq_names.txt"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    benchmark:"benchmarks/grab_intergenic_names_{gtdb_species}.txt"
    shell:"""
    grep '>' {input} | awk 'sub(/^>/, "")' > {output}
    """

rule combine_pangenome_and_intergenic_sequences:
    input: 
        "outputs/gtdb_genomes_annotated_comb/{gtdb_species}_clustered_annotated_seqs.fa",
        "outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_clustered_intergenic_seqs.fa"
    output: "outputs/gtdb_genomes_salmon_ref/{gtdb_species}.fa"
    threads: 1
    resources: 
        mem_mb=2000,
        tmpdir=TMPDIR
    benchmark:"benchmarks/combine_sequences_{gtdb_species}.txt"
    shell:'''
    cat {input} > {output}
    '''

rule index_transcriptome:
    input: 
        seqs="outputs/gtdb_genomes_salmon_ref/{gtdb_species}.fa",
        decoys="outputs/gtdb_genomes_intergenic_comb/{gtdb_species}_clustered_intergenic_seq_names.txt"
    output: "outputs/gtdb_genomes_salmon_index/{gtdb_species}/info.json"
    threads: 1
    params: index_dir = lambda wildcards: "outputs/gtdb_genomes_salmon_index/" + wildcards.gtdb_species
    resources: 
        mem_mb=16000,
        tmpdir=TMPDIR
    conda: "envs/salmon.yml"
    benchmark:"benchmarks/salmon_index_{gtdb_species}.txt"
    shell:'''
    salmon index -t {input.seqs} -i {params.index_dir} --decoys {input.decoys} -k 31
    '''



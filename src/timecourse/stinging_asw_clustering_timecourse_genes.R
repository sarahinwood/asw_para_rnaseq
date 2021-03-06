library("DESeq2")
library("data.table")
library("ggplot2")
library("dplyr")

seed <- 6

  ##function to calculate geometric mean
gm_mean <- function(x, na.rm=TRUE){
  exp(sum(log(x[x > 0]), na.rm = na.rm) / length(x))
}

  ##read in dds saved in previous script
dds <- readRDS("output/asw_timecourse/deseq2/dds_abdo.rds")
  ##filter for only abdo samples
dds_abdo <- dds[,dds$Tissue == "Abdomen"]
  ##read in list of sig gene names
sig_gene_names <- fread("output/asw_timecourse/deseq2/timecourse_sig_gene_names.csv")[,unique(sig_gene_names)]

  ##vst log transform data - absolute counts now changed so cannot compare between genes (only between samples for 1 gene)
vst <- varianceStabilizingTransformation(dds_abdo, blind = FALSE)
  ##make matrix of transformed data
vst_matrix <- data.table(as.matrix(assay(vst)), keep.rownames = TRUE)
  ##melt to make long table rather than wide
long_vst_data <- melt(vst_matrix, id.vars = "rn", variable.name = "Sample_name", value.name = "vst")
  ##make table of colData from dds object
long_coldata <- data.table(as.data.frame(colData(dds_abdo)))

  ##merge sample data with vst data
merged_exp_coldata <- merge(long_vst_data, long_coldata, all.x = TRUE, all.y = FALSE)
  ##generate table of mean vst values
mean_vst <- merged_exp_coldata[,.(vst_mean = gm_mean(vst)),by=.(rn, Treatment)]
  ##make long table a wide table instead
mean_vst_wide <- dcast(mean_vst, rn~Treatment)
  ##make matrix with gene names as row names
expression_matrix <- as.matrix(data.frame(mean_vst_wide, row.names = "rn"))

  ##linking treatment labels to treatments
pheno_data <- data.frame(row.names = colnames(expression_matrix), treatment = colnames(expression_matrix))
vg <- ExpressionSet(assayData = expression_matrix[sig_gene_names,], phenoData = new('AnnotatedDataFrame', data = pheno_data))

##run from here down on biochemcompute - can't on my laptop - using bioconductor singularity image
library(Mfuzz)
seed <- 6
set.seed(seed)
##standardise expression values to have mean of 0 and st dev of 1 - necessary for mfuzz
vg_s <- standardise(vg)
#optimise parameters - mestimate(vg_s)?
##m determines influence of noise on cluster analysis - increasing m reduces the influence of genes with low membership values
#m prevents clustering of random data
##mestimate gave 2.97 for short tc - but don't want it this high???
##gave 2.3 for longer tc, but this sig.reduces no. genes in clusters
m <- 2
#use to determine no. clusters - Dmin = mindist between clusters, should decline slower after reaching optimal no. of clusters
x <- Dmin(vg_s, m, crange = seq(4, 16, 1), repeats = 1)
diff(x)

#c=no. clusters
##4 missing real pattern, 6 has 2 clusters with same pattern, 7+ has clusters with only 1 gene
c1 <- mfuzz(vg_s, c = 5, m=m)
clusters<- acore(vg_s, c1, min.acore = 0.7)

##mfuzz cluster plot
pdf("output/asw_timecourse/mfuzz/mfuzz_plot.pdf")
##centre=TRUE, centre.col="black", centre.lwd=4 - puts a thick black line through middle of each cluster showing average pattern
mfuzz.plot2(vg_s, c1, mfrow = c(3, 2), min.mem = 0.7, x11=FALSE, time.labels=c("Control", "30", "120", "240", "480"), xlab="Minutes")
dev.off()

cluster_membership <- rbindlist(clusters, idcol = "cluster")

cluster_expr_wide <- data.table(exprs(vg_s), keep.rownames = TRUE)
setnames(cluster_expr_wide, "rn", "NAME")
cluster_expr <- melt(cluster_expr_wide,
                     id.vars = "NAME",
                     variable.name = "time",
                     value.name = "scaled_vst")

cluster_pd <- merge(cluster_membership,
                    cluster_expr,
                    by = "NAME",
                    all.x = TRUE,
                    all.y = FALSE)
fwrite(cluster_pd, "output/asw_timecourse/mfuzz/gene_clusters.csv")

##Can do from here on laptop - can play with and change m and cluster #
cluster_pd <- fread("output/asw_timecourse/mfuzz/gene_clusters.csv")
##prep table for plotting
time_order <- c("Control", "m30", "m120", "m240", "m480")
cluster_pd[,time:=factor(time, levels = time_order)]
setnames(cluster_pd, old=c("MEM.SHIP"), new=c("Cluster Membership"))
cluster_pd$cluster_label <- paste("Cluster", cluster_pd$cluster)

####ideally the x axis would be spread out across time rather than discrete#####
ggplot(cluster_pd, aes(x = time,
                       y = scaled_vst,
                       colour = `Cluster Membership`,
                       group = NAME)) +
  theme_minimal(base_size = 8) +
  xlab("Minutes") + ylab("Scaled, mapped reads") +
  facet_wrap(~ cluster_label, scales="fixed") +
  geom_line()

##add trinotate annot.s to all DEGs in other script then pull out clustered genes here

##to add manual blast annotations to clusters - back on my laptop
deg_annotations <- fread("output/asw_timecourse/deseq2/degs_trinotate_blastx_annots.csv")
clusters <- fread("output/asw_timecourse/mfuzz/gene_clusters.csv")
cluster_annotations <- merge(clusters, deg_annotations, by.x="NAME", by.y="#gene_id")
dedup_cluster_annots <- cluster_annotations[cluster_annotations$time == "Control",]
fwrite(dedup_cluster_annots, "output/asw_timecourse/mfuzz/clusters_trinotate_and_blastx_annots.csv")

##Read in interpro results
interpro_results <- fread("output/asw_timecourse/interproscan/interproscan_degs.fasta.tsv", fill=TRUE)
setnames(interpro_results, old=c("V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "V10", "V11", "V12", "V13", "V14"), new=c("transcript_id", "Seq MD5 digest", "Seq. length", "Analysis", "Signature Accession", "Signature Description", "Start", "Stop", "e-value", "Status", "Date", "InterPro Annotation Accession", "InterPro Annotation Description", "GO Terms"))

##fix transcript id
interpro_transcript_id <- interpro_results[,tstrsplit(transcript_id, "_")]
interpro_results$transcript_id <- paste(interpro_transcript_id$V1,"_",interpro_transcript_id$V2,"_",interpro_transcript_id$V3,"_",interpro_transcript_id$V4,"_",interpro_transcript_id$V5, sep="")
##Filter for columns I want
interpro_annots <- select(interpro_results, transcript_id, `Signature Description`, `e-value`, `InterPro Annotation Description`, `GO Terms`)
fwrite(interpro_annots, "output/asw_timecourse/interproscan/interpro_descriptions.csv")

clustered_genes <- unique(clusters$NAME)
non_clustered_genes <- data.table(setdiff(sig_gene_names, clustered_genes))
all_annots_degs <- fread("output/asw_timecourse/deseq2/degs_trinotate_blastx_annots.csv")
non_clustered_annots <- merge(x = non_clustered_genes, all_annots_degs, by.x = "V1", by.y = "#gene_id", all.x = TRUE, all.y = FALSE)
fwrite(non_clustered_annots, "output/asw_timecourse/deseq2/non_clustered_sig_degs_annots.csv")



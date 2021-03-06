#===============================================================================
#       Load libraries
#===============================================================================

library(DESeq2)
library("BiocParallel")
register(MulticoreParam(12))
library(data.table)
library(plyr)
library(dplyr)
library(vegan)
library(lmPerm)
library(ggplot2)
library(devtools)
load_all("~/pipelines/metabarcoding/scripts/myfunctions")
library(Biostrings)
#===============================================================================
#       Load data 
#===============================================================================

# load denoised otu count table
countData <- read.table("BAC.otus_table.txt",header=T,sep="\t",row.names=1, comment.char = "")

# load sample metadata
colData <- read.table("colData",header=T,sep="\t",row.names=1,colClasses=c("factor"))

# load taxonomy data
taxData <- read.table("BAC.taxa",header=F,sep=",",row.names=1)

# reorder columns
taxData<-taxData[,c(1,3,5,7,9,11,13,2,4,6,8,10,12,14)]

# add best "rank" at 0.65 confidence and tidy-up the table
taxData<-phyloTaxaTidy(taxData,0.65)

# save data into a list
ubiom_BAC <- list(countData=countData,colData=colData,taxData=taxData,RHB="BAC")

# Fungi all in one call
ubiom_FUN <- list(
	countData=read.table("FUN.otus_table.txt",header=T,sep="\t",row.names=1,comment.char = ""),
	colData=read.table("colData",header=T,sep="\t",row.names=1,colClasses=c("factor")),
	taxData=phyloTaxaTidy(read.table("FUN.taxa",header=F,sep=",",row.names=1)[,c(1,3,5,7,9,11,13,2,4,6,8,10,12,14)],0.65),
	RHB="FUN"
) 

#===============================================================================
#       Combine species 
#===============================================================================

#### combine species at 0.95 (default) confidence (if they are species)

# list of species with more than one associated OTU
invisible(mapply(assign, names(ubiom_FUN), ubiom_FUN, MoreArgs=list(envir = globalenv())))
combinedTaxa <- combineTaxa("FUN.taxa")
countData <- combCounts(combinedTaxa,countData)
taxData <- combTaxa(combinedTaxa,taxData)
ubiom_FUN$countData <- countData
ubiom_FUN$taxData <- taxData

#===============================================================================
#       Attach objects
#===============================================================================

# attach objects (either FUN or BAC)
invisible(mapply(assign, names(ubiom_FUN), ubiom_FUN, MoreArgs=list(envir = globalenv())))
invisible(mapply(assign, names(ubiom_BAC), ubiom_BAC, MoreArgs=list(envir = globalenv())))

#===============================================================================
#       Create DEseq objects 
#===============================================================================

# ensure colData rows and countData columns have the same order
colData <- colData[names(countData),]

# remove low count samples
filter <- colSums(countData)>=1000
colData <- droplevels(colData[filter,])
countData <- countData[,filter]

# simple Deseq design
design<-~1

#create DES object
# colnames(countData) <- row.names(colData)
dds<-DESeqDataSetFromMatrix(countData,colData,design)

# calculate size factors - three different methods given...
# the default method 
sizeFactors(dds) <- sizeFactors(estimateSizeFactors(dds))
# use if the min and max sizeFactors from the above are too disperate (say >10x), or method throws error (same as geoMeans(dds) - but no built into deseq)
# sizeFactors(dds) <- sizeFactors(estimateSizeFactors(dds,type="poscounts"))
# or use edgeR's calcNormFactors which itself includes multiple normalisation methods (RLE, TMM, upperquantile)
# library(edgeR) 
# calcNormFactors(counts(dds),method="RLE",lib.size=(prop.table(colSums(counts(dds))))) # original DESeq method, other options also available using calcNormFactors

#===============================================================================
#       Collapse replicates
#===============================================================================

# the three sample points from the same locations are likely to be highly correlated 
# DESeq doesn't have a method for handling correlated DVs
# one possible correction is to collapse the replicates to the mean
# collapseReplicates2 will adjust for different library sizes - results won't be exact as dds counts must be integer values (could multiply them all by longest decimal if really wanted)
dds <- collapseReplicates2(dds,groupby=paste0(dds$condition,dds$pair),simple=F)
# extract new colData from the dds object
colData <- as.data.frame(colData(dds))

#===============================================================================
#       Filter data 
#============================================================================

### read accumulation filter
# plot cummulative reads (will also produce a data table "dtt" in the global environment)
ggsave(paste(RHB,"OTU_counts.pdf",sep="_"),plotCummulativeReads(counts(dds,normalize=T)))

#### Select filter ####
myfilter <- dtt$OTU[dtt$CD>5]
# myfilter <- dtt$OTU[1:500] 
# filter out low abundance OTUs
dds <- dds[myfilter,]

#===============================================================================
#       PCA plot
#===============================================================================

# perform PC decomposition of DES object
mypca <- des_to_pca(dds)

# to get pca plot axis into the same scale create a dataframe of PC scores multiplied by their variance
df <-t(data.frame(t(mypca$x)*mypca$percentVar))

# plot the PCA
pdf(paste(RHB,"PCA.pdf",sep="_"))
plotOrd(df,colData,design="condition",shape="pair",xlabel="PC1",ylabel="PC2")

### remove/minimise run effect (pretty useless in this case as the run (single sample point) explains the vast majority of the variance for this sample)
pc.res <- resid(aov(mypca$x~colData$pair,colData)) 
df <- t(data.frame(t(pc.res*mypca$percentVar)))
plotOrd(df,colData,design="condition",shape="pair",xlabel="PC1",ylabel="PC2")
dev.off()

#===============================================================================
#       differential analysis
#===============================================================================

# p value for FDR cutoff
alpha <- 0.1

### test for ARD effect in paired samples ###
dds2 <- dds[,(dds$Row=="52"|dds$Row=="53")&dds$pair!="6"]
dds2$pair <- droplevels(dds2$pair)
dds2$condition <- droplevels(dds2$condition)
# filter for low counts
myfilter <- dtt$OTU[1:500] 
dds2 <- dds2[myfilter,]
#dds2<-dds2[rowSums(counts(dds2,normalize=T))>0,]
# the full model 
full_design <- ~pair+condition
# add full model to dds object
design(dds2) <- full_design
# calculate fit
dds2 <- DESeq(dds2,parallel=T)
# get results
res <- results(dds2,alpha=alpha,parallel=T)
# merge with taxonomy
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
# write resuts
write.table(res.merge, paste(RHB,"ARD_candidates.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
# output significant otu fasta
writeXStringSet(readDNAStringSet(paste0(RHB,".otus.fa"))[res.merge[padj<=0.1]$OTU],paste0(RHB,".ARD.sig.fa"))


#######

### test for ARD in all samples ###
dds2 <- dds[,dds$Row!=""]
dds2$pair <- droplevels(dds2$pair)
dds2$condition <- droplevels(dds2$condition)
dds2$position <- droplevels(dds2$position)
myfilter <- dtt$OTU[1:500] 
dds2 <- dds2[myfilter,]
full_design <- ~position+condition
design(dds2) <- full_design
dds2 <- DESeq(dds2,parallel=T)
res <- results(dds2,alpha=alpha,parallel=T)
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
write.table(res.merge, paste(RHB,"ARD_candidates_all_samples.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
writeXStringSet(readDNAStringSet(paste0(RHB,".otus.fa"))[res.merge[padj<=0.1]$OTU],paste0(RHB,".ARD_all.sig.fa"))
######

### test for difference between tree stations and aisles (fully paired) ###
dds2 <- dds[,(dds$pair!="5")&(dds$pair!="6")]
dds2$pair <- droplevels(dds2$pair)
dds2$condition <- droplevels(dds2$condition)
dds2$type <- as.factor(sub("^[B|E].*","aisle",sub("^[L|S].* ","",dds2$condition)))
full_design <- ~pair+type
design(dds2) <- full_design
dds2 <- DESeq(dds2,parallel=T)
res <- results(dds2,alpha=alpha,parallel=T)
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
write.table(res.merge, paste(RHB,"tree_aisle.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
#######

### test for difference between tree stations and aisles (all samples) ###
dds2 <- dds
dds2$type <- as.factor(sub("^[B|E].*","aisle",sub("^[L|S].* ","",dds2$condition)))
full_design <- ~pair+type
design(dds2) <- full_design
dds2 <- DESeq(dds2,parallel=T)
res <- results(dds2,alpha=alpha,parallel=T)
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
write.table(res.merge, paste(RHB,"tree_aisle_all_samples.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
#######

#===============================================================================
#       Alpha diversity analysis
#===============================================================================

# plot alpha diversity - plot_alpha will convert normalised abundances to integer values (limits for bac only)
ggsave(paste(RHB,"Alpha.pdf",sep="_"),plot_alpha(counts(dds,normalize=T),colData,design="pair",colour="condition"))

### permutation based anova on diversity index ranks ###

# get the diversity index data
all_alpha_ord <- plot_alpha(counts(dds,normalize=T),colData,design="condition",colour="block",returnData=T)

# add column names as row to metadata (or use tribble)
colData$Samples <- rownames(colData)

# join diversity indices and metadata
all_alpha_ord <- as.data.table(inner_join(all_alpha_ord,colData))

# perform anova for each index
sink(paste(RHB,"ALPHA_stats.txt",sep="_"))
setkey(all_alpha_ord,S.chao1)
summary(aovp(as.numeric(as.factor(all_alpha_ord$S.chao1))~condition+Error(treatment),all_alpha_ord))
setkey(all_alpha_ord,shannon)
summary(aovp(as.numeric(as.factor(all_alpha_ord$shannon))~condition+Error(treatment),all_alpha_ord))
setkey(all_alpha_ord,simpson)
summary(aovp(as.numeric(as.factor(all_alpha_ord$simpson))~condition+Error(treatment),all_alpha_ord))
setkey(all_alpha_ord,S.ACE)
summary(aovp(as.numeric(as.factor(all_alpha_ord$S.ACE))~condition+Error(treatment),all_alpha_ord))
sink()

#This is the HPC-friendly version of the NanoMeth Rmarkdown to generate the 1,000 resamples for feature selection runs using
# Boruta. This is a _very_ computationally heavy aspect of the work and takes several hours to complete. The results are saved as 
# a RDS object for local computation afterwards. Much of this script is repeated from the first chunk of the markdown, just to 
# ensure that if you have punted this to a cluster, you still have all the objects required for computation

################ Load libraries, set params ####################
#Cleaning and munging:
library(tidyverse)
library(magrittr)
library(here)

#Modelling & Computation:
library(Boruta)
library(yardstick)
library(rsample)
library(furrr)

#Set the RNG version (because original analyses done with 3.5.3)
RNGversion("3.5.3")
set.seed(2903)

#Define the number of resamples wanted:
n_resamples <- 1000
#Set the parallelisation options:
plan(multisession)

################ Import data, set variables ################
## Read in the ExoMeth dataset and the ExoMeth metastatic dataframes:
ExoMeth_Cohort <- readRDS(here("ExoMeth", "data", "ExoMeth_Cohort.RDS"))
MetsSamples    <- readRDS(here("ExoMeth", "data", "ExoMeth_Mets.RDS"))

## Define the different groups of dataframe variables needed for analysis:
#Methylation:
MethProbes <- c("mGSTP1", "mAPC", "mSFRP2", "mIGFBP3", "mIGFBP7", "mPTGS2")
#Clinical:
ClinVars <- c("PSA", "UrineVol", "DRESize", "Age")
#The outcomes assessed later on (see data dictionary for formal definition):
outcomes <- c("Cat", "TriSig", "GleaSig", "LowGSig", "ClinSig", 
              "is_C")

#The NanoString variables (lazily from the ExoMeth dataframe)
NanoGenes <- ExoMeth_Cohort %>% 
  select(-Sample_ID, -ClinVars, -outcomes, -MethProbes, -Gleason) %>% 
  colnames

################ FEATURE SELECTION RUNS ################
set.seed(2903) #To be sure to be sure
#Produce the many resamples required to run boruta on:
ExoMethResamples <- bootstraps(ExoMeth_Cohort, 
                               times = n_resamples, 
                               strata = "TriSig") 

# Create a helper function to apply boruta to resamples one at a time:
SingleSampleBoruta <- function(Splits,
                               Variables,
                               Target){
  #Grab the dataframe from the specified split:
  TrainData = Splits$data
  #Apply Boruta to the dataframe:
  Bor = Boruta(x = TrainData[, Variables],
               y = TrainData[[Target]],
               maxRuns = 100)
  #Pull out the importance history from Boruta and coerce to a tibble
  Importances = Bor[["ImpHistory"]] %>% 
    as_tibble() %>%
    #Change to long form
    gather(key = "Variable", value = "Importance") %>% 
    # Merge the importance histories with the final decision for each variable:
    left_join(
      Bor[["finalDecision"]] %>% 
        #Coerce to dataframe (retaining rownames from Boruta matrix)
        as.data.frame %>% 
        #Set up the column names by coercing the rownames to a column
        rownames_to_column("Variable") %>% 
        set_colnames(c("Variable", "Decision")), 
      by = "Variable")
  return(Importances)
}

######################## BORUTA RUNS ########################
# This is the meat of the feature reduction; it maps through each comparator set of variables 
# and runs boruta on each of the resamples. It also takes forever. For the final runs this will
# be pushed to the HPC for computation and left to run, with the results saved.
ResampledBoruta <-
  # For each of the different choices of variables, apply the boruta resample function above
  map(list(ClinVars, MethProbes, NanoGenes,
           c(NanoGenes, MethProbes, ClinVars)),
      function(Variables){
        #Apply and join the boruta function to each resample:
        map_dfr(ExoMethResamples$splits, function(Resample){
          #Generate the decisions for each resample with the helper function:
          SingleSampleBoruta(Splits = Resample, Variables = Variables, Target = "TriSig")
        }) %>%
          # Calculate the proportion of resamples each variable was confirmed in:
          group_by(Variable) %>%
          mutate(Proportion = length(which(Decision == "Confirmed"))/length(Decision)) %>%
          ungroup() %>%
          #Create a final decision variable, based on the proportions calculated above
          #This can be used to select how "stable" a feature must be before being chosen
          #and is somewhat redundant in the ExoMeth works, where variables are confirmed
          #100% of the time or <50%.
          mutate(FinalDecision = case_when(
            str_detect(Variable, "shadow") ~ "Shadow",
            Proportion < 0.4 ~ "Rejected",
            Proportion < 0.90 ~ "Tentative",
            Proportion >= 0.90 ~ "Confirmed")
          )
      }) %>%
  #Set the final comparator model names
  set_names(c("SoC", "Methylation", "ExoRNA", "ExoMeth"))


# Extract the important variables for each set of input variables and produce a list for later use:
ConfirmedVariables <- map(
  # Loop through each resample of the Boruta runs
  ResampledBoruta, function(Single_Boruta) {
    Single_Boruta %>%
      # Filter only "confirmed" variables
      filter(FinalDecision == "Confirmed") %>%
      # Select only the variables and make a distinct list of them
      select(Variable) %>%
      distinct() %>%
      as_vector()
  }
) %>%
  set_names(c("SoC", "Methylation", "ExoRNA", "ExoMeth"))

#Take the Boruta results from each set of comparator variables and process them ready to be plotted,
#This makes quite a big object, not particularly binder-friendly
FeatureImportances <- map(ResampledBoruta, function(Comparator){
  Comparator %>%
    filter(Importance != -Inf) %>%
    filter(Decision %in% c("Confirmed", "Tentative", NA)) %>%
    mutate(
      Variable = str_remove(Variable, "^m"),
      # Bind the proportions so that they can be filled in nicely on a plot:
      Proportion = case_when(
        Proportion <= 0.05 ~ "<5%",
        Proportion <= 0.25 ~ "5 - 25%",
        Proportion <= 0.50 ~ "25 - 50%",
        Proportion <= 0.75 ~ "50 - 75%",
        Proportion <= 0.90 ~ "75 - 90%",
        Proportion >= 0.90 ~ ">90%"
      ),
      # Mutate the Shadow feature strings to look nice:
      Proportion = if_else(str_detect(Variable, "shadow"),
                           "Shadow Feature",
                           Proportion
      ),
      Variable = str_replace(Variable, "shadowMax", "Shadow Maximum"),
      Variable = str_replace(Variable, "shadowMin", "Shadow Minimum"),
      Variable = str_replace(Variable, "shadowMean", "Shadow Mean"),
      # Make sure Proportion is an ordered factor.
      Proportion = factor(Proportion,
                          levels = c(
                            "<5%", "5 - 25%", "25 - 50%", "50 - 75%", "75 - 90%", ">90%",
                            "Shadow Feature"
                          ),
                          ordered = TRUE
      )
    )
})

#Save the results to an RDS for local work:
saveRDS(ResampledBoruta, here("ExoMeth/output/data_out/ResampledBoruta.RDS"))
saveRDS(ConfirmedVariables, here("ExoMeth/output/data_out/ConfirmedVariables.RDS"))
saveRDS(FeatureImportances, here("ExoMeth/output/data_out/FeatureImportances.RDS"))


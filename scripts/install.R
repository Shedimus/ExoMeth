# R packages --------------------------------------------------------------
# This will check if you have the required packages by attempting to load them (through pacman) and if not, installs them.
if (!require(pacman)) install.packages("pacman"); library(pacman)

# Cleaning and munging:
p_load(tidyverse)
p_load(magrittr)
p_load(here)

# Modelling:
p_load(Boruta)
p_load(randomForest)

# Computation
p_load(furrr)
p_load(pROC)
p_load(yardstick)
p_load(rmda)
p_load(splitstackshape)

# Making things pretty:
p_load(formattable)
p_load(qwraps2)
p_load(ggpubr)
p_load(ggsci)
p_load(dabestr)
p_load(cowplot)
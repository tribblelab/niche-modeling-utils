# niche_modeling_utils
# niche_modeling_utils

## to instantiate Julia pkgs for the first time:

to instantiate / load packages from `\niche_modelingutils` directory:

`julia --project`

```{julia}
using Pkg
# install the packages listed in the environment
Pkg.instantiate()
```

## R package dependencies + install

```{R}
packages <- c("gatoRs", "ggplot2", "sf", "ggspatial", "gridExtra", "CoordinateCleaner", "readxl", "dplyr")
new_packages <- packages[!(packages %in% installed.packages()[,"Package"])]
if(length(new_packages)) install.packages(new_packages)
```
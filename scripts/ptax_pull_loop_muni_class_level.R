# File & Loop Prep ----------------------------------------
## AWM & MVH ##
## 12-30-23 ##

library(tidyverse)
library(DBI)
library(data.table)
library(gstat)
library(here)
library(httr)
library(jsonlite)
library(ptaxsim)
library(stars)
library(glue)

# Create the DB connection with the default name expected by PTAXSIM functions

# AWM filepath:
ptaxsim_db_conn <- DBI::dbConnect(RSQLite::SQLite(), "./ptaxsim.db/ptaxsim-2023.0.0.db")

# MVH filepath:
# ptaxsim_db_conn <- DBI::dbConnect(RSQLite::SQLite(), "ptaxsim.db")

# Load supplemental files w/ "clean" muni names and detail re: class codes.

class_dict <- read_csv("./Necessary_Files/class_dict_expanded.csv") %>% select(-loa_2022)


nicknames <- readxl::read_excel("./Necessary_Files/muni_shortnames.xlsx")

 # Set years for loop to run.

years <-(2006:2023)

# Create empty dataframes for the loop to populate.
muni_class_summary <- NULL
muni_tc_summary <- NULL


commercial_classes <- c(401:435, 490, 491, 492, 496:499,
                        500:535,590, 591, 592, 597:599,
                        700:799,
                        800:835, 891, 892, 897, 899)   %>% as.character()

industrial_classes <- c(480:489,493,
                        550:589, 593,
                        600:699,
                        850:890, 893 ) %>% as.character()



is.integer64 <- function(x){
  class(x)=="integer64"
}


# Loop Start --------------------------------------------------------------



for(i in years){

  year_variable = i

  # PTAXSIM tables ---------------------------------------

  ## Municipality taxing agencies only + Cicero
  muni_agency_names <- DBI::dbGetQuery(
    ptaxsim_db_conn,
    "SELECT DISTINCT agency_num, agency_name, minor_type
    FROM agency_info
    WHERE minor_type = 'MUNI'
    OR agency_num = '020060000'
    "
  )


  agency_dt<- dbGetQuery(ptaxsim_db_conn, paste('SELECT * FROM agency WHERE year = ', i, ';'))
  agency_dt <- agency_dt %>%  mutate_if(is.integer64, as.double)

  tax_codes <- dbGetQuery(ptaxsim_db_conn, paste('SELECT DISTINCT tax_code_num, tax_code_rate FROM tax_code WHERE year = ', i, ';'))



  sql <- "SELECT * FROM tax_code WHERE agency_num IN ({muni_agency_names$agency_num*}) AND year = ?year"
  query <- sqlInterpolate(ptaxsim_db_conn, sql, year = i)
  muni_tax_codes<- dbGetQuery(ptaxsim_db_conn, glue_sql(query, .con = ptaxsim_db_conn))

  tif_distrib <- DBI::dbGetQuery(ptaxsim_db_conn, paste('SELECT * FROM tif_distribution WHERE year = ', i, ';'))


  ## All tax codes.
  ## tax codes within municipalities have additional info
  tc_muninames <- tax_codes %>%
    left_join(muni_tax_codes) %>%
    left_join(muni_agency_names) %>%
    select(-agency_rate) %>%
    left_join(nicknames) %>%
    select(-c(minor_type, short_name,
              agency_number))




  sql <- "SELECT DISTINCT pin, class, tax_code_num FROM pin WHERE tax_code_num IN ({tax_codes$tax_code_num*}) AND year = ?year"
  query <- sqlInterpolate(ptaxsim_db_conn, sql, year = i)
  cook_pins <- dbGetQuery(ptaxsim_db_conn, glue_sql(query, .con = ptaxsim_db_conn))



  # combine taxing agency names and agency type to data table that has eav and extension values
  agency_data <- right_join(agency_dt, muni_agency_names) %>%
    select(-c(cty_dupage_eav:cty_livingston_eav)) %>% # drop some of the unused variables
    arrange(agency_num)


  eq_factor <- read_csv("./Necessary_Files/eq_factor.csv") %>%
    filter(year == i) %>%
    select(eq_factor_final) %>%
    as.numeric()

  ccao_loa <- read_csv("./inputs/ccao_loa.csv") %>%
    mutate(class_code = as.character(class_code)) %>%
    filter(year == i) %>%
    select(-year) %>%
    mutate(loa = as.numeric(loa)) %>%
    mutate(loa = ifelse(loa == 0, NA, loa))

  # Tax Bills ---------------------------------------------------------------


  # pin-taxing agency combinations for tax bills
  taxbills <- tax_bill(year_variable,  cook_pins$pin,
                       simplify = FALSE)


  #  billed properties with 14-digit PINs
  pin14_bills <- taxbills %>%
    mutate_if(is.integer64, as.double) %>%
    group_by(tax_code, class, pin) %>%

    mutate(total_bill = final_tax_to_dist + final_tax_to_tif, # from each taxing agency
           eq_av = av/eq_factor) %>%

    group_by(tax_code, class, pin) %>%


    summarize(total_billed = sum(total_bill, na.rm = TRUE), # total on someone's property tax bill
              av = first(av),            # PINs appear multiple times, uses first av appearance
              eq_av = first(eq_av),      # equalized AV = potential taxable value for homeowners
              eav = first(eav),          # EAV after exemptions are subtracted.
              taxing_agency_count = n(), # number of taxing agencies that tax the pin
              final_tax_to_dist = sum(final_tax_to_dist, na.rm = TRUE), # portion of all levies paid by the pin
              final_tax_to_tif = sum(final_tax_to_tif, na.rm = TRUE),
              tax_amt_exe = sum(tax_amt_exe, na.rm = TRUE),           # revenue lost due to exemptions
              tax_amt_pre_exe = sum(tax_amt_pre_exe, na.rm = TRUE),   # total rev before all exemptions
              tax_amt_post_exe = sum(tax_amt_post_exe, na.rm = TRUE), # total rev after all exemptions
              rpm_tif_to_cps = sum(rpm_tif_to_cps, na.rm = TRUE),     # not used currently
              rpm_tif_to_rpm = sum(rpm_tif_to_rpm, na.rm=TRUE),       # not used currently
              rpm_tif_to_dist = sum(rpm_tif_to_dist, na.rm=TRUE),     # not used currently
              tif_share = mean(tif_share, na.rm=TRUE),                # not used currently
    )  %>%
    mutate(propclass_1dig = str_sub(class, 1, 1))

  rm(taxbills)



  # Exemptions at PIN level --------------------------------------------------


  # finds all pins within Cook county and data on their exemptions
  # joins tax code variable by pin

  exemption_data <- lookup_pin(i, cook_pins$pin) %>%
    mutate_if(is.integer64, as.double ) %>%

    left_join(cook_pins, by = c("pin", "class")) %>%

    # Future step for potential future obtained loa's
    # Also takes care of different levels of assessment in past years
    left_join(ccao_loa, by = c("class" = "class_code")) %>%

    mutate(all_exemptions = exe_homeowner + exe_senior + exe_freeze + exe_longtime_homeowner +
             exe_disabled + exe_vet_returning + exe_vet_dis_lt50 + exe_vet_dis_50_69 + exe_vet_dis_ge70 ,
           abatements = exe_abate,          # abatements get their own variable
           fmv = av / loa,
           ) %>%

    # Create binary variables for exemptions
    mutate(zero_bill = ifelse(eav <= all_exemptions, 1, 0),
           has_HO_exemp = ifelse(exe_homeowner > 0, 1, 0),
           has_SF_exemp = ifelse(exe_senior > 0, 1, 0),
           has_FR_exemp = ifelse(exe_freeze > 0, 1, 0),
           has_LTHO_exemp = ifelse(exe_longtime_homeowner > 0, 1, 0),
           has_DI_exemp = ifelse(exe_disabled > 0, 1, 0),
           has_VR_exemp = ifelse(exe_vet_returning > 0, 1, 0),
           has_DV_exemp = ifelse(exe_vet_dis_lt50 + exe_vet_dis_50_69 + exe_vet_dis_ge70 > 0, 1, 0),
           has_AB_exemp = ifelse(exe_abate > 0, 1, 0),
           in_tif = ifelse(tax_code_num %in% tif_distrib$tax_code_num, 1, 0)
    )

  rm(cook_pins)


  # change variable type to character so the join works.
  class_dict$class_code <- as.character(class_dict$class_code)

  # use the property class to make the major property types
  # joins the class_dict file to the pin_data classes
  exemption_data <- class_dict %>%
    right_join(exemption_data, by = c("class_code" = "class"),
               relationship = "many-to-many")


  # Summarize PIN Exemptions ------------------------------------------------



  # Join Bills and Exemptions  ----------------------------------------------

  ## Add exemption types and values to the tax bill data at PIN level
  joined_pin_data <- left_join(pin14_bills, exemption_data, by = c("pin", "class" = "class_code" ))  %>%
    rename(av = av.x,
           eav =  eav.x,         # first(eav) from tax bills
           equalized_av = eav.y) # eav from pin table

  rm(exemption_data)


  ## Add tax code tax rate to PIN level data
  joined_pin_data <- left_join(joined_pin_data, tc_muninames, by = c("tax_code" = "tax_code_num"))



  # Summarize ---------------------------------------------------------------
joined_pin_data <- joined_pin_data %>%
  mutate(
    incent_prop = ifelse(between(class, 600, 899), 1, 0),
    res_prop = ifelse(between(class, 200, 399), 1, 0),
    c2_prop = ifelse(between(class, 200, 299), 1, 0),
    class_group = str_sub(class, 1,1),
    class_group = case_when(
           (class_group == 5 & class %in% commercial_classes) ~ "5A",
           (class_group == 5 & class %in% industrial_classes) ~ "5B",
           class_group == 7 &  class < 742 ~ "7A",    # commercial developments less than $2 million
           class_group == 7 &  class >= 742 ~ "7B",   # commercial developments greater than $2 million
           (class_group == 8 & class %in% commercial_classes ) ~ "8A",
           (class_group == 8 & class %in% industrial_classes ) ~ "8B",
           TRUE ~ as.character(class_group))) %>%
    mutate(
      # taxing district revenue = taxed eav * tax rate so rearrange the formula:
      taxed_eav = final_tax_to_dist / tax_code_rate*100,
      
      # total value eav based on current levels of assessment
      total_value_eav = (final_tax_to_dist + final_tax_to_tif)/ tax_code_rate * 100 + all_exemptions + abatements,

      taxed_av =  taxed_eav / eq_factor,     # current value that taxing agencies can tax for their levies

      ## taxable AV = equalized assessed value net TIF increments, gross exemptions.
      ## Used for calculating untaxable value further below
      taxable_av = (final_tax_to_dist / tax_code_rate *100 + all_exemptions + abatements)/ eq_factor,

      ## FMV * assessment rate = AV
      taxed_fmv = taxed_av / loa,
      fmv = av / loa,

      ## untaxable value = exempt EAV from abatements and exemptions plus TIF increment plus dif in incentive prop values from loa rates
      untaxable_value_eav = all_exemptions + abatements +

        ## TIF increment EAV above frozen EAV, which becomes TIF revenue
        (final_tax_to_tif /  tax_code_rate*100) +

        ## difference between 25% and reduced level of assessment for incentive class properties. Excludes TIF increment when calculating the difference!
        ifelse(incent_prop == 1,
               (taxable_av - taxed_av)*eq_factor, 0),

      #  manually adjust untaxable value of class 239 properties
      untaxable_value_eav = ifelse(class == 239,
                                   equalized_av-taxed_eav, untaxable_value_eav),

      untaxable_value_av = untaxable_value_eav / eq_factor,
      untaxable_value_fmv = untaxable_value_av / loa,
      untaxable_value_fmv = ifelse(is.nan(untaxable_value_av), 0, untaxable_value_av),

      exempt_eav_inTIF = ifelse(in_tif == 1,
                                all_exemptions, 0),
      exempt_eav= all_exemptions + abatements,
      exempt_fmv = exempt_eav / eq_factor / loa,
    #  exempt_fmv = ifelse(is.nan(exempt_fmv), 0 , exempt_fmv),


      fmv_inTIF = ifelse(in_tif==1,
                         av/loa, 0),

      fmv_tif_increment = ifelse(final_tax_to_tif > 0,
                                 ((final_tax_to_tif / (tax_code_rate/100)) / eq_factor ) / loa, 0),

      fmv_incents_inTIF = ifelse(incent_prop == 1 & in_tif == 1,
                                 fmv, 0),
      fmv_incents_tif_increment = ifelse(incent_prop == 1 & final_tax_to_tif > 0 ,
                                    ((final_tax_to_tif / (tax_code_rate/100)) / eq_factor ) / loa, 0),

      eav_incents_inTIF = fmv_incents_inTIF * loa * eq_factor
    ) %>%
    select(tax_code, class, pin, taxed_fmv,
           untaxable_value_fmv, fmv_inTIF, fmv_tif_increment, fmv, total_billed, final_tax_to_dist, final_tax_to_tif, tax_code_rate, eav, equalized_av, av, everything())

  ### Muni-Class (3-digit)  Summary ---------------------------------------------------------


  muni_class_summary2 <- joined_pin_data %>%
    group_by(clean_name, class)  %>%

    summarize(
      av = sum(av, na.rm = TRUE),
      eav = sum(eav, na.rm = TRUE),
      equalized_av = sum(equalized_av, na.rm = TRUE),
      pins_in_muni = n(),

      all_exemptions = sum(all_exemptions, na.rm = TRUE),

      exe_homeowner = sum(exe_homeowner, na.rm=TRUE),
      exe_senior = sum(exe_senior, na.rm=TRUE),
      exe_freeze = sum(exe_freeze, na.rm=TRUE),
      exe_longtime_homeowner = sum(exe_longtime_homeowner, na.rm=TRUE),
      exe_disabled = sum(exe_disabled, na.rm=TRUE),
      exe_vet_returning = sum(exe_vet_returning, na.rm=TRUE),
      exe_vet_dis_lt50 = sum(exe_vet_dis_lt50, na.rm=TRUE),
      exe_vet_dis_50_69 = sum(exe_vet_dis_50_69, na.rm=TRUE),
      exe_vet_dis_ge70 = sum(exe_vet_dis_ge70, na.rm=TRUE),
      exe_abate = sum(exe_abate, na.rm=TRUE),

      exe_vet_dis = sum(exe_vet_dis_lt50 + exe_vet_dis_50_69 +
                          exe_vet_dis_ge70, na.rm=TRUE),  # all vet_dis variables added together

      tax_code_rate = mean(tax_code_rate, na.rm = TRUE),          # Changed from first() to mean() on Nov 1
      final_tax_to_dist = sum(final_tax_to_dist, na.rm = TRUE),   # used as LEVY amount!!
      final_tax_to_tif = sum(final_tax_to_tif, na.rm = TRUE),     # TIF increment
      tax_amt_exe = sum(tax_amt_exe, na.rm = TRUE),
      tax_amt_pre_exe = sum(tax_amt_pre_exe, na.rm = TRUE),
      tax_amt_post_exe = sum(tax_amt_post_exe, na.rm = TRUE),
      rpm_tif_to_cps = sum(rpm_tif_to_cps, na.rm = TRUE), # not used
      rpm_tif_to_rpm = sum(rpm_tif_to_rpm, na.rm=TRUE),   # not used
      rpm_tif_to_dist = sum(rpm_tif_to_dist, na.rm=TRUE), # not used
      tif_share = mean(tif_share, na.rm=TRUE),

      zero_bills = sum(zero_bill, na.rm=TRUE),
      has_HO_exemp = sum(has_HO_exemp, na.rm=TRUE),
      has_SF_exemp = sum(has_SF_exemp, na.rm=TRUE),
      has_FR_exemp = sum(has_FR_exemp, na.rm=TRUE),
      has_LTHO_exemp = sum(has_LTHO_exemp, na.rm=TRUE),
      has_DI_exemp = sum(has_DI_exemp, na.rm=TRUE),
      has_VR_exemp = sum(has_VR_exemp, na.rm=TRUE),
      has_DV_exemp = sum(has_DV_exemp, na.rm=TRUE),
      has_AB_exemp = sum(has_AB_exemp, na.rm=TRUE)

    ) %>%

    mutate(total_bill_current = final_tax_to_dist + final_tax_to_tif) %>%
    rename(cur_comp_muni_rate = tax_code_rate) %>%
    mutate(current_taxable_eav = final_tax_to_dist/(cur_comp_muni_rate/100),
           year = year_variable ) %>%
    select(year, clean_name, class, cur_comp_muni_rate, current_taxable_eav, everything()) %>%
    setNames(paste0('muni_c_', names(.)))


  # bind muni level yearly data together
  if(is.data.frame(muni_class_summary)){muni_class_summary <- rbind(muni_class_summary, muni_class_summary2)}else{muni_class_summary <- muni_class_summary2}
  rm(muni_class_summary2)

 }


# Rename Variables -------------------------------------------------------

muni_class_summary <- muni_class_summary %>%
  rename(clean_name = muni_c_clean_name,
         year = muni_c_year,
         class = muni_c_class
)
# Export CSVs ------------------------------------------------------------



write_csv(muni_class_summary, "./Output/ptaxsim_muni_class_summaries_2006to2023.csv")


# write_csv(tc_mc_summaries, "./Output/ptaxsim_TC_MC_summaries_2006-2022.csv")
# write_csv(tc_class_summaries, "./Output/ptaxsim_TC_Class_summaries_2006-2022.csv")


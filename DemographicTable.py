from DemographicScript import Master_Cohort
import pandas as pd
import neuroblu as nb
from tableone import TableOne


def main():
    
    cohort_name = "Demo_Cohort"
        
    print("Demographics Table 1")
    
    #load cohort and save if it isnt saved already
    try:
        dataframe = nb.get_df(cohort_name)
    except:
        nb.save_df(nb.get_query(Master_Cohort()), cohort_name, 1)
        dataframe = nb.get_df(cohort_name)

    columns = ['age_at_index', 'sex', 'race', 'ethnicity']
    category = ['sex', 'race', 'ethnicity']
    table = TableOne(dataframe, columns=columns, categorical=category)
    print(table.tabulate(tablefmt='fancy_grid'))
    table.to_csv('table1.csv')


    

    

    
    
    



if __name__ == "__main__":
    main()
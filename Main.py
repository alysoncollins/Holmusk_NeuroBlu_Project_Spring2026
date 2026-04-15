from Cutoff_Script import Master_Cohort
import pandas as pd
import neuroblu as nb
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder
import Models

def main():
    cohort_name = "AVG_Cohort"
        
    print("Cutoff Based Standardization")
    
    #load cohort and save if it isnt saved already
    try:
        dataframe = nb.get_df(cohort_name)
    except:
        nb.save_df(nb.get_query(Master_Cohort()), cohort_name, 1)
        dataframe = nb.get_df(cohort_name)
    print(len(dataframe))

    
    #split data into predictors and outcome measurements
    PredictorsX = dataframe.drop(columns=['person_id', 'index_date', 'cutoff_score', 'test_date', 'prev_test_date', 'prev_score', 'score_delta_from_last', 'trajectory'])
    TargetY = dataframe['trajectory']

    # Encode trajectory labels
    le = LabelEncoder()
    TargetY = pd.Series(le.fit_transform(TargetY), name='trajectory')
    print(f"Classes: {list(le.classes_)}")

    feature_names = PredictorsX.columns.tolist()
    target_names  = list(le.classes_)
    
    X_train, X_test, Y_train, Y_test = train_test_split(PredictorsX, TargetY, test_size=0.2, random_state=42)

    
    Models.randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.xgboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)

def Parameters():
    pass
    
if __name__ == "__main__":
    main()
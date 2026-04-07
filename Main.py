from Cutoff_Script import Master_Cohort
import pandas as pd
import neuroblu as nb
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder
import Models

def main():
    print("Cutoff Based Standardization")
    
    #load cohort and save if it isnt saved already
    try:
        dataframe = nb.get_df("Cohort")
    except:
        nb.save_df(nb.get_query(Master_Cohort()), "Cohort", 1)
        dataframe = nb.get_df("Cohort")
        
    dataframe, encoders = preprocess(dataframe)

    #split data into predictors and outcome measurements
    PredictorsX = dataframe.drop(columns=['person_id', 'score_delta', 'last_score', 'avg_followup_score', 'first_score', 'index_date'])
    TargetY = dataframe[['score_delta', 'last_score', 'avg_followup_score']]

    feature_names = PredictorsX.columns.tolist()
    target_names  = TargetY.columns.tolist()
    
    X_train, X_test, Y_train, Y_test = train_test_split(PredictorsX, TargetY, test_size=0.2, random_state=42)
    
    Models.randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.scikit_GB_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)
    Models.lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names)

    
def preprocess(dataframe):
    df = dataframe.copy()
    
    # Encode categorical columns
    categorical_cols = ['sex', 'race', 'ethnicity']
    encoders = {}
    for col in categorical_cols:
        le = LabelEncoder()
        df[col] = le.fit_transform(df[col].astype(str))
        encoders[col] = le  # saved in case you need to decode later
    
    # Drop rows with missing values in X or Y columns
    df = df.dropna(subset=['age_at_index', 'sex', 'race', 'ethnicity',
                            'first_score', 'score_delta', 'last_score', 'avg_followup_score'])
    return df, encoders
    
if __name__ == "__main__":
    main()
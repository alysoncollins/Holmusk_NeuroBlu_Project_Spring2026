from Cutoff_Script import Master_Cohort
import pandas as pd
from sklearn.model_selection import GroupShuffleSplit

setattr(pd, "Int64Index", pd.Index)
setattr(pd, "Float64Index", pd.Index)
    
import neuroblu as nb
from scipy.stats import pearsonr
import numpy as np
from sklearn.impute import SimpleImputer
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

    
    #split data into predictors and outcome measurements
    PredictorsX = dataframe.drop(columns=['person_id', 'index_date', 'cutoff_score', 'test_date', 'prev_test_date', 'prev_score', 'score_delta_from_last', 'trajectory'])
    PredictorsX = PredictorsX.astype(float)

    # Encode trajectory labels
    le = LabelEncoder()
    dataframe['trajectory_encoded'] = le.fit_transform(dataframe['trajectory'])

    TargetY = dataframe['trajectory_encoded']

    feature_names = PredictorsX.columns.tolist()
    target_names  = list(le.classes_)

    
    person_ids = dataframe['person_id']
    gss = GroupShuffleSplit(n_splits=1, test_size=0.2, random_state=42)
    train_idx, test_idx = next(gss.split(dataframe, dataframe['trajectory_encoded'], groups=person_ids))
    
    X_train = dataframe.iloc[train_idx][feature_names]
    X_test  = dataframe.iloc[test_idx][feature_names]
    Y_train = dataframe.iloc[train_idx]['trajectory_encoded']
    Y_test  = dataframe.iloc[test_idx]['trajectory_encoded']
    train_groups = dataframe.iloc[train_idx]['person_id'].values

    imputer = SimpleImputer(strategy="median")
    # Drop columns with fewer than 5 non-zero values
    sparse_cols = [col for col in X_train.columns if (X_train[col] != 0).sum() < 5]
    if sparse_cols:
        print(f"Dropping {len(sparse_cols)} sparse columns: {sparse_cols}")
        X_train = X_train.drop(columns=sparse_cols)
        X_test  = X_test.drop(columns=sparse_cols)
        feature_names = [f for f in feature_names if f not in sparse_cols]
        print(f"Remaining features: {len(feature_names)}")
    X_train = pd.DataFrame(imputer.fit_transform(X_train), columns=feature_names)
    X_test  = pd.DataFrame(imputer.transform(X_test),      columns=feature_names)

    ### diagnostics
    #num of entries
    print(len(dataframe))
    #correlation to check for data leakage
    numeric_X = PredictorsX.select_dtypes(include='number')
    target_vals = TargetY.astype(float).values

    correlations = pd.Series({
        col: pearsonr(numeric_X[col].fillna(0).values, target_vals)[0]
        for col in numeric_X.columns
    }).abs().sort_values(ascending=False)
    print("\n--- Feature Correlations with Target ---")
    print(correlations)
    ###

    print(f"Label encoding: {dict(zip(le.classes_, le.transform(le.classes_)))}")

    print(feature_names)
    print("Rows and Columns after preprocessing")
    print(X_train.shape)
    
    train_groups = dataframe.iloc[train_idx]['person_id'].values

    Models.randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups=train_groups)
    Models.catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups=train_groups)
    Models.lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups=train_groups)
    Models.xgboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups=train_groups)

def Parameters():
    pass
    
if __name__ == "__main__":
    main()

from Cutoff_Script import Master_Cohort
import pandas as pd
import neuroblu as nb
from sklearn.ensemble import RandomForestRegressor
from sklearn.multioutput import MultiOutputRegressor
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error
from sklearn.preprocessing import LabelEncoder

def main():
    #load prexisting dataframe
    #in the future a way to refresh the dataframe will be added
    #dataframe = readDF()
    dataframe = nb.get_query(Master_Cohort())
    dataframe, encoders = preprocess(dataframe)

    #split data into predictors and outcome measurements
    PredictorsX = dataframe.drop(columns=['person_id', 'score_delta', 'last_score', 'avg_followup_score', 'first_score'])
    TargetY = dataframe[['score_delta', 'last_score', 'avg_followup_score']]

    feature_names = PredictorsX.columns.tolist()
    target_names  = TargetY.columns.tolist()
    
    X_train, X_test, Y_train, Y_test = train_test_split(PredictorsX, TargetY, test_size=0.2, random_state=42)
    
    randomforest(X_train, Y_train, X_test, Y_test, target_names, feature_names)


def randomforest(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    rf_model = MultiOutputRegressor(RandomForestRegressor(n_estimators=100, random_state=42))
    rf_model.fit(X_train, Y_train)
    rf_preds = rf_model.predict(X_test)
    
    #MSE values for each Y
    #MSE shows how close the prediction was to the actual result
    #lower is closer to prediction
    print("\n--- Random Forest MSE per Target ---")
    for i, col in enumerate(target_names):
        mse = mean_squared_error(Y_test.iloc[:, i], rf_preds[:, i])
        print(f"  {col}: {mse:.4f}")
    print(f"  Overall MSE: {mean_squared_error(Y_test, rf_preds):.4f}")
    
    #runs importance function for randomforest
    rf_importance = get_feature_importance(rf_model, feature_names, target_names)
    print("\n--- Random Forest Feature Importance ---")
    print(rf_importance)
    
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

def get_feature_importance(model, feature_names, target_names):
    """Average feature importance across all Y target models"""
    importance_df = pd.DataFrame()
    
    for i, estimator in enumerate(model.estimators_):
        importance_df[target_names[i]] = estimator.feature_importances_
    
    importance_df.index = feature_names
    importance_df['average_importance'] = importance_df.mean(axis=1)
    importance_df = importance_df.sort_values('average_importance', ascending=False)
    
    return importance_df
    

def saveDF():
    #WIP
    dataset = nb.get_query(Master_Cohort())
    nb.save_df(dataset, "Cohort_Table", 1)
    

def readDF():
    return nb.get_df("Cohort_Table")
    

if __name__ == "__main__":
    main()
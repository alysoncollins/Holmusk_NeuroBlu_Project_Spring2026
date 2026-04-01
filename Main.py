from Cutoff_Script import Master_Cohort
import pandas as pd
import neuroblu as nb
from sklearn.ensemble import RandomForestRegressor
from sklearn.multioutput import MultiOutputRegressor
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error
from sklearn.preprocessing import LabelEncoder
import numpy as np
import shap
import matplotlib.pyplot as plt
np.bool = bool #fix for mismatched numpy and shap version



def main():
    print("Cutoff Based Standardization")
    #load prexisting dataframe
    #in the future a way to refresh the dataframe will be added
    dataframe = readDF()
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

    shap_plots(rf_model, X_test, feature_names, target_names)
    
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
    
    datetime_cols = df.select_dtypes(include=['datetime64']).columns.tolist()
    for col in datetime_cols:
        df[col] = (df[col] - pd.Timestamp("1970-01-01")).dt.days
    
    return df, encoders

def get_feature_importance(model, feature_names, target_names):
    """Average feature importance across all Y target models"""
    importance_df = pd.DataFrame()
    
    for i, estimator in enumerate(model.estimators_):
        importance_df[target_names[i]] = estimator.feature_importances_
    
    importance_df.index = feature_names
    importance_df['average_importance'] = importance_df.mean(axis=1)
    importance_df = importance_df.sort_values('average_importance', ascending=False)
    
    return importance_df.head(20)

def shap_plots(rf_model, X_test, feature_names, target_names):

    X_test_array = X_test.values if hasattr(X_test, 'values') else X_test

    for i, estimator in enumerate(rf_model.estimators_):
        target = target_names[i]
        print(f"\nGenerating SHAP plots for: {target}")

        explainer   = shap.TreeExplainer(estimator)
        shap_values = explainer.shap_values(X_test_array)  # shape: (n_samples, n_features)

        # --- Bar plot: mean absolute SHAP per feature ---
        mean_abs_shap = np.abs(shap_values).mean(axis=0)
        sorted_idx    = np.argsort(mean_abs_shap)

        fig, ax = plt.subplots(figsize=(8, 6))
        ax.barh(
            [feature_names[j] for j in sorted_idx],
            mean_abs_shap[sorted_idx],
            color='steelblue'
        )
        ax.set_xlabel("Mean |SHAP Value|")
        ax.set_title(f"SHAP Importance — {target}")
        plt.tight_layout()
        plt.savefig(f"shap_bar_{target}.png", dpi=150)
        plt.close(fig)

        # --- Beeswarm: manual scatter per feature ---
        fig, ax = plt.subplots(figsize=(8, 6))
        for j in sorted_idx:
            feature_vals = X_test_array[:, j]
            shap_vals    = shap_values[:, j]

            # Normalize feature values to [0,1] for coloring
            vmin, vmax = feature_vals.min(), feature_vals.max()
            norm_vals  = (feature_vals - vmin) / (vmax - vmin + 1e-9)

            ax.scatter(
                shap_vals,
                np.full_like(shap_vals, j),
                c=norm_vals,
                cmap='coolwarm',
                alpha=0.5,
                s=15
            )

        ax.set_yticks(range(len(feature_names)))
        ax.set_yticklabels([feature_names[j] for j in sorted_idx])
        ax.axvline(0, color='black', linewidth=0.8, linestyle='--')
        ax.set_xlabel("SHAP Value")
        ax.set_title(f"SHAP Beeswarm — {target}")

        sm = plt.cm.ScalarMappable(cmap='coolwarm', norm=plt.Normalize(0, 1))
        sm.set_array([])
        plt.colorbar(sm, ax=ax, label="Feature Value (normalized)")

        plt.tight_layout()
        plt.savefig(f"shap_beeswarm_{target}.png", dpi=150)
        plt.close(fig)

        print(f"  Saved: shap_beeswarm_{target}.png")
        print(f"  Saved: shap_bar_{target}.png")

def saveDF():
    #WIP
    dataset = nb.get_query(Master_Cohort())
    nb.save_df(dataset, "Cohort_Table", 1)
    

def readDF():
    return nb.get_df("Drug_Cohort")
    

if __name__ == "__main__":
    main()
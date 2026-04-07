from sklearn.ensemble import RandomForestRegressor
from catboost import CatBoostRegressor
from sklearn.ensemble import GradientBoostingRegressor
from lightgbm import LGBMRegressor
from sklearn.multioutput import MultiOutputRegressor
from sklearn.metrics import mean_squared_error
import pandas as pd
import Graph

def get_feature_importance(model, feature_names, target_names):
    """Average feature importance across all Y target models"""
    importance_df = pd.DataFrame()
    
    for i, estimator in enumerate(model.estimators_):
        importance_df[target_names[i]] = estimator.feature_importances_
    
    importance_df.index = feature_names
    importance_df['average_importance'] = importance_df.mean(axis=1)
    importance_df = importance_df.sort_values('average_importance', ascending=False)
    
    return importance_df.head(20)

def randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    #parameters
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

    Graph.shap_plots(rf_model, X_test, feature_names, target_names, "random_forest")

def catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    #parameters
    cb_model = MultiOutputRegressor(CatBoostRegressor(
        iterations=500,
        learning_rate=0.05,
        depth=6,
        random_seed=42,
        verbose=0  # suppresses per-iteration output
    ))
    cb_model.fit(X_train, Y_train)
    cb_preds = cb_model.predict(X_test)

    print("\n--- CatBoost MSE per Target ---")
    for i, col in enumerate(target_names):
        mse = mean_squared_error(Y_test.iloc[:, i], cb_preds[:, i])
        print(f"  {col}: {mse:.4f}")
    print(f"  Overall MSE: {mean_squared_error(Y_test, cb_preds):.4f}")

    cb_importance = get_feature_importance(cb_model, feature_names, target_names)
    print("\n--- CatBoost Feature Importance ---")
    print(cb_importance)

    Graph.shap_plots(cb_model, X_test, feature_names, target_names, "catboost")


def scikit_GB_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    xgb_model = MultiOutputRegressor(GradientBoostingRegressor(
        n_estimators=500,
        learning_rate=0.05,
        max_depth=6,
        random_state=42
    ))
    xgb_model.fit(X_train, Y_train)
    xgb_preds = xgb_model.predict(X_test)

    print("\n--- Gradient Boosting MSE per Target ---")
    for i, col in enumerate(target_names):
        mse = mean_squared_error(Y_test.iloc[:, i], xgb_preds[:, i])
        print(f"  {col}: {mse:.4f}")
    print(f"  Overall MSE: {mean_squared_error(Y_test, xgb_preds):.4f}")

    xgb_importance = get_feature_importance(xgb_model, feature_names, target_names)
    print("\n--- Gradient Boosting Feature Importance ---")
    print(xgb_importance)

    Graph.shap_plots(xgb_model, X_test, feature_names, target_names, "scikit-learn_GB")


def lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    #parameters
    lgbm_model = MultiOutputRegressor(LGBMRegressor(
        n_estimators=500,
        learning_rate=0.05,
        max_depth=6,
        random_state=42,
        verbose=-1  # suppresses output
    ))
    lgbm_model.fit(X_train, Y_train)
    lgbm_preds = lgbm_model.predict(X_test)

    print("\n--- LightGBM MSE per Target ---")
    for i, col in enumerate(target_names):
        mse = mean_squared_error(Y_test.iloc[:, i], lgbm_preds[:, i])
        print(f"  {col}: {mse:.4f}")
    print(f"  Overall MSE: {mean_squared_error(Y_test, lgbm_preds):.4f}")

    lgbm_importance = get_feature_importance(lgbm_model, feature_names, target_names)
    print("\n--- LightGBM Feature Importance ---")
    print(lgbm_importance)

    Graph.shap_plots(lgbm_model, X_test, feature_names, target_names, "lightgbm")
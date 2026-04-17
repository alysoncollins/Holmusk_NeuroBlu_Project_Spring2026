from sklearn.ensemble import RandomForestClassifier
from catboost import CatBoostClassifier
from lightgbm import LGBMClassifier
from sklearn.metrics import classification_report, accuracy_score,average_precision_score, precision_recall_curve
from xgboost import XGBClassifier
from sklearn.metrics import log_loss
import pandas as pd
import Graph
import matplotlib.pyplot as plt

def get_feature_importance(model, feature_names):
    """Feature importance for single-output classifiers"""
    importance_df = pd.DataFrame({
        'feature': feature_names,
        'importance': model.feature_importances_
    }).sort_values('importance', ascending=False)
    return importance_df.head(10)

def randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    rf_model = RandomForestClassifier(n_estimators=100, random_state=42)
    rf_model.fit(X_train, Y_train)
    
    rf_preds = rf_model.predict(X_test)
    rf_probs = rf_model.predict_proba(X_test)

    print("\n--- Random Forest Classification Report ---")
    print(classification_report(Y_test, rf_preds, target_names=target_names))
    print(f"  Accuracy: {accuracy_score(Y_test, rf_preds):.4f}")
    print(f"  Log Loss: {log_loss(Y_test, rf_probs):.4f}")

    train_probs    = rf_model.predict_proba(X_train)[:, 1]
    test_probs     = rf_probs[:, 1]
    train_pr_auc   = average_precision_score(Y_train, train_probs)
    test_pr_auc    = average_precision_score(Y_test, test_probs)
    print(f"  Train PR-AUC: {train_pr_auc:.3f}")
    print(f"  Test  PR-AUC: {test_pr_auc:.3f}")

    precision, recall, _ = precision_recall_curve(Y_test, test_probs)
    plt.figure(figsize=(8, 5))
    plt.plot(recall, precision)
    plt.axhline(y=Y_test.mean(), color='k', linestyle='--', label=f"Random baseline ({Y_test.mean():.2f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title("Random Forest - Precision-Recall Curve")
    plt.legend()
    plt.savefig("pr_curve_Random_Forest.png", bbox_inches='tight', dpi=150)
    plt.close()

    rf_importance = get_feature_importance(rf_model, feature_names)
    print("\n--- Random Forest Feature Importance ---")
    print(rf_importance)
    Graph.shap_plots(rf_model, X_test, feature_names, target_names, "random_forest")


def catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    cb_model = CatBoostClassifier(
        iterations=500,
        learning_rate=0.05,
        depth=6,
        random_seed=42,
        verbose=0
    )
    cb_model.fit(X_train, Y_train)
    
    cb_preds = cb_model.predict(X_test)
    cb_probs = cb_model.predict_proba(X_test)

    print("\n--- CatBoost Classification Report ---")
    print(classification_report(Y_test, cb_preds, target_names=target_names))
    print(f"  Accuracy: {accuracy_score(Y_test, cb_preds):.4f}")
    print(f"  Log Loss: {log_loss(Y_test, cb_probs):.4f}")

    train_probs  = cb_model.predict_proba(X_train)[:, 1]
    test_probs   = cb_probs[:, 1]
    train_pr_auc = average_precision_score(Y_train, train_probs)
    test_pr_auc  = average_precision_score(Y_test, test_probs)
    print(f"  Train PR-AUC: {train_pr_auc:.3f}")
    print(f"  Test  PR-AUC: {test_pr_auc:.3f}")

    precision, recall, _ = precision_recall_curve(Y_test, test_probs)
    plt.figure(figsize=(8, 5))
    plt.plot(recall, precision)
    plt.axhline(y=Y_test.mean(), color='k', linestyle='--', label=f"Random baseline ({Y_test.mean():.2f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title("CatBoost - Precision-Recall Curve")
    plt.legend()
    plt.savefig("pr_curve_CatBoost.png", bbox_inches='tight', dpi=150)
    plt.close()

    cb_importance = get_feature_importance(cb_model, feature_names)
    print("\n--- CatBoost Feature Importance ---")
    print(cb_importance)
    Graph.shap_plots(cb_model, X_test, feature_names, target_names, "catboost")


def lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    lgbm_model = LGBMClassifier(
        n_estimators=500,
        learning_rate=0.05,
        max_depth=6,
        random_state=42,
        verbose=-1
    )
    lgbm_model.fit(X_train, Y_train)
    
    lgbm_preds = lgbm_model.predict(X_test)
    lgbm_probs = lgbm_model.predict_proba(X_test)

    print("\n--- LightGBM Classification Report ---")
    print(classification_report(Y_test, lgbm_preds, target_names=target_names))
    print(f"  Accuracy: {accuracy_score(Y_test, lgbm_preds):.4f}")
    print(f"  Log Loss: {log_loss(Y_test, lgbm_probs):.4f}")

    train_probs  = lgbm_model.predict_proba(X_train)[:, 1]  # fixed bug here
    test_probs   = lgbm_probs[:, 1]
    train_pr_auc = average_precision_score(Y_train, train_probs)
    test_pr_auc  = average_precision_score(Y_test, test_probs)
    print(f"  Train PR-AUC: {train_pr_auc:.3f}")
    print(f"  Test  PR-AUC: {test_pr_auc:.3f}")

    precision, recall, _ = precision_recall_curve(Y_test, test_probs)
    plt.figure(figsize=(8, 5))
    plt.plot(recall, precision)
    plt.axhline(y=Y_test.mean(), color='k', linestyle='--', label=f"Random baseline ({Y_test.mean():.2f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title("LightGBM - Precision-Recall Curve")
    plt.legend()
    plt.savefig("pr_curve_LightGBM.png", bbox_inches='tight', dpi=150)
    plt.close()

    lgbm_importance = get_feature_importance(lgbm_model, feature_names)
    print("\n--- LightGBM Feature Importance ---")
    print(lgbm_importance)
    Graph.shap_plots(lgbm_model, X_test, feature_names, target_names, "lightgbm")


def xgboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names):
    xgb_model = XGBClassifier(
        n_estimators=500,
        learning_rate=0.05,
        max_depth=6,
        random_state=42,
        eval_metric='mlogloss',
        verbosity=0,
        tree_method='hist'
    )
    xgb_model.fit(X_train, Y_train)
    
    xgb_preds = xgb_model.predict(X_test)
    xgb_probs = xgb_model.predict_proba(X_test)

    print("\n--- XGBoost Classification Report ---")
    print(classification_report(Y_test, xgb_preds, target_names=target_names))
    print(f"  Accuracy: {accuracy_score(Y_test, xgb_preds):.4f}")
    print(f"  Log Loss: {log_loss(Y_test, xgb_probs):.4f}")

    train_probs  = xgb_model.predict_proba(X_train)[:, 1]
    test_probs   = xgb_probs[:, 1]
    train_pr_auc = average_precision_score(Y_train, train_probs)
    test_pr_auc  = average_precision_score(Y_test, test_probs)
    print(f"  Train PR-AUC: {train_pr_auc:.3f}")
    print(f"  Test  PR-AUC: {test_pr_auc:.3f}")

    precision, recall, _ = precision_recall_curve(Y_test, test_probs)
    plt.figure(figsize=(8, 5))
    plt.plot(recall, precision)
    plt.axhline(y=Y_test.mean(), color='k', linestyle='--', label=f"Random baseline ({Y_test.mean():.2f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title("XGBoost - Precision-Recall Curve")
    plt.legend()
    plt.savefig("pr_curve_xgboost.png", bbox_inches='tight', dpi=150)
    plt.close()

    xgb_importance = get_feature_importance(xgb_model, feature_names)
    print("\n--- XGBoost Feature Importance ---")
    print(xgb_importance)
    Graph.shap_plots(xgb_model, X_test, feature_names, target_names, "xgboost")